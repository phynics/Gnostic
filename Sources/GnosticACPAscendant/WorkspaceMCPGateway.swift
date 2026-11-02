// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@MainActor
final class WorkspaceMCPGateway {
    private struct Tool {
        let workspaceID: UUID
        let providerToolID: String
        let definition: BackendWorkspaceTool
        let gatewayName: String
    }

    private let timelineID: UUID
    private let timelineRegistry: AscendantTimelineRegistry
    private let workspaceService: any AscendantBackendWorkspaceService
    private let timelineJournalRecorder: TimelineJournalRecorder?
    private let permissionService: any AscendantBackendPermissionService
    private let activeTurn: @MainActor (UUID) -> (clientTurnID: String, sessionID: String)?
    private var server: WorkspaceMCPHTTPServer?

    init(
        timelineID: UUID,
        timelineRegistry: AscendantTimelineRegistry,
        workspaceService: any AscendantBackendWorkspaceService,
        permissionService: any AscendantBackendPermissionService,
        timelineJournalRecorder: TimelineJournalRecorder? = nil,
        activeTurn: @escaping @MainActor (UUID) -> (clientTurnID: String, sessionID: String)?
    ) {
        self.timelineID = timelineID
        self.timelineRegistry = timelineRegistry
        self.workspaceService = workspaceService
        self.permissionService = permissionService
        self.timelineJournalRecorder = timelineJournalRecorder
        self.activeTurn = activeTurn
    }

    func start() throws -> ACPMcpServer {
        if let server { return server.configuration }
        let token = "\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let server = try WorkspaceMCPHTTPServer(token: token) { [weak self] request in
            guard let self else { return nil }
            return await self.handle(request)
        }
        do {
            try server.start()
        } catch {
            server.stop()
            throw error
        }
        self.server = server
        return server.configuration
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func handle(_ request: ACPJSONRPCRequest) async -> ACPJSONRPCResponse {
        switch request.method {
        case "initialize":
            let version: String
            if case let .object(params)? = request.params,
               case let .string(value)? = params["protocolVersion"],
                ["2025-03-26", "2025-06-18", "2025-11-25"].contains(value) {
                version = value
            } else {
                version = "2025-03-26"
            }
            return response(id: request.id, result: .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("gnostic-workspace-gateway"), "version": .string("0.5.0")]),
            ]))
        case "ping":
            return response(id: request.id, result: .object([:]))
        case "tools/list":
            let tools = await availableTools()
            return response(id: request.id, result: .object([
                "tools": .array(tools.map { tool in
                    .object([
                        "name": .string(tool.gatewayName),
                        "description": .string("Workspace \(tool.workspaceID.uuidString): \(tool.definition.description)"),
                        "inputSchema": Self.schema(tool.definition.parametersSchema),
                    ])
                }),
            ]))
        case "tools/call":
            return await callTool(request)
        default:
            return ACPJSONRPCResponse(id: request.id, error: ACPJSONRPCError(
                code: ACPv2Protocol.ErrorCode.methodNotFound,
                message: "Unknown MCP method."
            ))
        }
    }

    private func callTool(_ request: ACPJSONRPCRequest) async -> ACPJSONRPCResponse {
        guard case let .object(params)? = request.params,
              case let .string(name)? = params["name"] else {
            return error(request.id, code: ACPv2Protocol.ErrorCode.invalidParams, "tools/call requires a tool name.")
        }
        let arguments: [String: ManifestJSONValue]
        switch params["arguments"] {
        case nil:
            arguments = [:]
        case let .object(values)?:
            arguments = values.mapValues(Self.manifestValue)
        default:
            return error(request.id, code: ACPv2Protocol.ErrorCode.invalidParams, "tools/call arguments must be an object.")
        }
        guard let tool = await availableTools().first(where: { $0.gatewayName == name }) else {
            return error(request.id, code: -32003, "Workspace tool is not attached or is unavailable.")
        }
        guard timelineRegistry.attachedWorkspaceIDs(for: timelineID).contains(tool.workspaceID) else {
            return error(request.id, code: -32003, "Workspace is not attached to this Timeline.")
        }
        var permissionApproved = false
        if tool.definition.requiresPermission {
            guard let turn = activeTurn(timelineID) else {
                return error(request.id, code: -32003, "Workspace tool requires an active, approved Turn.")
            }
            let permissionRequest = BackendPermissionRequest(
                timelineID: timelineID,
                clientTurnID: turn.clientTurnID,
                toolCallID: "mcp-\(UUID().uuidString.lowercased())",
                title: "Run Workspace tool \(tool.definition.name)"
            )
            let decision = await permissionService.requestApproval(for: permissionRequest)
            let value: String
            switch decision {
            case .approved: value = "approved"
            case .denied: value = "denied"
            case .unavailable: value = "unavailable"
            }
            do {
                try await timelineJournalRecorder?.appendPermissionDecision(
                    timelineID: timelineID, clientTurnID: turn.clientTurnID,
                    correlationID: permissionRequest.correlationID, decision: value, approved: decision.isApproved
                )
            } catch {
                return self.error(request.id, code: -32003, "Workspace permission could not be committed.")
            }
            guard decision == .approved,
                  let current = activeTurn(timelineID), current.clientTurnID == turn.clientTurnID,
                  current.sessionID == turn.sessionID else {
                return error(request.id, code: -32003, "Workspace tool permission was not approved.")
            }
            permissionApproved = true
        }
        guard timelineRegistry.attachedWorkspaceIDs(for: timelineID).contains(tool.workspaceID),
              await availableTools().contains(where: { $0.gatewayName == name }) else {
            return error(request.id, code: -32003, "Workspace attachment or availability changed before dispatch.")
        }
        do {
            let result = try await workspaceService.invoke(BackendWorkspaceInvocation(
                timelineID: timelineID,
                permissionApproved: permissionApproved,
                workspaceID: tool.workspaceID,
                toolID: tool.providerToolID,
                arguments: arguments
            ))
            var fields: [String: ACPValue] = [
                "content": .array([.object(["type": .string("text"), "text": .string(Self.outputText(result))])]),
                "isError": .bool(!result.isSuccess),
            ]
            // MCP defines structured content as an object. Other values stay in the text content.
            if case .object? = result.value, let value = result.value {
                fields["structuredContent"] = Self.acpValue(value)
            }
            return response(id: request.id, result: .object(fields))
        } catch {
            return self.error(request.id, code: -32003, error.localizedDescription)
        }
    }

    private func availableTools() async -> [Tool] {
        let attached = timelineRegistry.attachedWorkspaceIDs(for: timelineID)
        var tools: [Tool] = []
        for workspaceID in attached {
            guard let reference = await workspaceService.reference(id: workspaceID), reference.status == .available else { continue }
            for definition in reference.tools {
                tools.append(Tool(
                    workspaceID: workspaceID,
                    providerToolID: definition.id,
                    definition: definition,
                    gatewayName: Self.gatewayToolName(workspaceID: workspaceID, toolID: definition.id)
                ))
            }
        }
        return tools.sorted { $0.gatewayName < $1.gatewayName }
    }

    private static func gatewayToolName(workspaceID: UUID, toolID: String) -> String {
        "workspace_\(workspaceID.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))__\(toolID)"
    }

    private func response(id: ACPRequestId, result: ACPValue) -> ACPJSONRPCResponse {
        ACPJSONRPCResponse(id: id, result: result)
    }

    private func error(_ id: ACPRequestId, code: Int, _ message: String) -> ACPJSONRPCResponse {
        ACPJSONRPCResponse(id: id, error: ACPJSONRPCError(code: code, message: message))
    }

    private static func schema(_ value: ManifestJSONValue?) -> ACPValue {
        guard case let .object(properties)? = value else { return .object(["type": .string("object")]) }
        var output = properties.mapValues(acpValue)
        output["type"] = output["type"] ?? .string("object")
        return .object(output)
    }

    private static func acpValue(_ value: ManifestJSONValue) -> ACPValue {
        switch value {
        case let .string(value): .string(value)
        case let .number(value): .double(value)
        case let .bool(value): .bool(value)
        case let .array(values): .array(values.map(acpValue))
        case let .object(values): .object(values.mapValues(acpValue))
        case .null: .null
        }
    }

    private static func outputText(_ result: BackendWorkspaceResult) -> String {
        guard let value = result.value else { return result.message ?? "" }
        if case let .string(text) = value { return text }
        guard let data = try? JSONEncoder().encode(value) else { return result.message ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func manifestValue(_ value: ACPValue) -> ManifestJSONValue {
        switch value {
        case let .string(value): .string(value)
        case let .int(value): .number(Double(value))
        case let .double(value): .number(value)
        case let .bool(value): .bool(value)
        case let .array(values): .array(values.map(manifestValue))
        case let .object(values): .object(values.mapValues(manifestValue))
        case .null: .null
        }
    }
}

@MainActor
private final class WorkspaceMCPHTTPServer {
    nonisolated private static let maximumRequestBytes = 1_048_576
    private let token: String
    private let handler: @MainActor @Sendable (ACPJSONRPCRequest) async -> ACPJSONRPCResponse?
    private var socketFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private(set) var configuration: ACPMcpServer = .other(type: "http", fields: [:])

    init(
        token: String,
        handler: @escaping @MainActor @Sendable (ACPJSONRPCRequest) async -> ACPJSONRPCResponse?
    ) throws {
        self.token = token
        self.handler = handler
        try bind()
    }

    func start() throws {
        guard socketFD >= 0, listen(socketFD, 16) == 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }) == 0 else { throw POSIXError(.EIO) }
        let port = UInt16(bigEndian: address.sin_port)
        configuration = .http(
            name: "gnostic-workspaces",
            url: "http://127.0.0.1:\(port)/mcp",
            headers: [.init(name: "Authorization", value: "Bearer \(token)")],
            meta: nil
        )
        let fd = socketFD
        acceptTask = Task.detached(
            executorPreference: BlockingIOTaskExecutor(label: "me.atkn.gnostic.acp.workspace-mcp")
        ) { [weak self] in
            while !Task.isCancelled {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                guard let self else { Self.close(client); break }
                let payload = Self.readRequest(client)
                let reply: HTTPReply
                if let payload {
                    reply = await self.handle(payload)
                } else {
                    reply = HTTPReply(status: 400, body: Data())
                }
                Self.writeReply(reply, to: client)
                Self.close(client)
            }
        }
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        if socketFD >= 0 {
            shutdown(socketFD, Int32(SHUT_RDWR))
            Self.close(socketFD)
            socketFD = -1
        }
    }

    private func handle(_ payload: HTTPRequest) async -> HTTPReply {
        guard payload.path == "/mcp" else { return HTTPReply(status: 404, body: Data()) }
        guard payload.method == "POST" else { return HTTPReply(status: 405, body: Data()) }
        guard payload.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return HTTPReply(status: 415, body: Data())
        }
        guard let accept = payload.headers["accept"]?.lowercased(),
              accept.contains("application/json"), accept.contains("text/event-stream") else {
            return HTTPReply(status: 406, body: Data())
        }
        guard payload.headers["authorization"] == "Bearer \(token)" else { return HTTPReply(status: 401, body: Data()) }
        guard let message = try? JSONDecoder().decode(ACPJSONRPCMessage.self, from: payload.body) else {
            return HTTPReply(status: 400, body: Data())
        }
        let isInitializeRequest: Bool
        if case let .request(request) = message {
            isInitializeRequest = request.method == "initialize"
        } else {
            isInitializeRequest = false
        }
        guard isInitializeRequest || payload.headers["mcp-protocol-version"] != nil else {
            return HTTPReply(status: 400, body: Data())
        }
        let requestedVersion: String?
        if case let .request(request) = message, request.method == "initialize",
           case let .object(params)? = request.params,
           case let .string(version)? = params["protocolVersion"] {
            requestedVersion = version
        } else {
            requestedVersion = payload.headers["mcp-protocol-version"]
        }
        if let requestedVersion,
           !["2025-03-26", "2025-06-18", "2025-11-25"].contains(requestedVersion) {
            return HTTPReply(status: 400, body: Data())
        }
        let responseHeaders = ["MCP-Protocol-Version": requestedVersion ?? "2025-03-26"]
        switch message {
        case let .request(request):
            guard let response = await handler(request), let body = try? JSONEncoder().encode(response) else {
                return HTTPReply(status: 202, body: Data(), headers: responseHeaders)
            }
            return HTTPReply(status: 200, body: body, headers: responseHeaders)
        case let .notification(notification):
            guard notification.method == "notifications/initialized" || notification.method == "notifications/cancelled" else {
                return HTTPReply(status: 202, body: Data(), headers: responseHeaders)
            }
            return HTTPReply(status: 202, body: Data(), headers: responseHeaders)
        case .response:
            return HTTPReply(status: 400, body: Data(), headers: responseHeaders)
        }
    }

    private func bind() throws {
        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #elseif canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, socketType, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x0100007f))
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #elseif canImport(Glibc)
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard result == 0 else {
            Self.close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        socketFD = fd
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct HTTPReply {
        let status: Int
        let body: Data
        var headers: [String: String] = [:]
    }

    nonisolated private static func readRequest(_ fd: Int32) -> HTTPRequest? {
        var data = Data()
        let delimiter = Data([13, 10, 13, 10])
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maximumRequestBytes {
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(fd, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumRequestBytes else { return nil }
            if let range = data.range(of: delimiter) {
                let headerData = data[..<range.lowerBound]
                guard let header = String(data: headerData, encoding: .utf8) else { return nil }
                let lines = header.components(separatedBy: "\r\n")
                guard let first = lines.first else { return nil }
                let parts = first.split(separator: " ")
                guard parts.count >= 2 else { return nil }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                        String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let contentLength = Int(headers["content-length"] ?? "0"), contentLength >= 0,
                      contentLength <= maximumRequestBytes else { return nil }
                let expectedSize = range.upperBound + contentLength
                guard expectedSize <= maximumRequestBytes else { return nil }
                if data.count >= expectedSize {
                    let body = data[range.upperBound..<expectedSize]
                    return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body))
                }
            }
        }
        return nil
    }

    nonisolated private static func writeReply(_ reply: HTTPReply, to fd: Int32) {
        let reason = switch reply.status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 415: "Unsupported Media Type"
        default: "Internal Server Error"
        }
        var header = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
        for (name, value) in reply.headers { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(reply.body)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                #if os(Linux)
                let count = send(fd, baseAddress.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL))
                #else
                let count = send(fd, baseAddress.advanced(by: sent), bytes.count - sent, 0)
                #endif
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    nonisolated private static func close(_ fd: Int32) {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #endif
    }
}
