// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GnosticACPWire
import PKContracts
import PositronicKit
import Synchronization

private let mcpRequestTimeoutSeconds: TimeInterval = 60 * 60

protocol MCPClient: Sendable {
    func initialize() async throws -> [WorkspaceToolDefinition]
    func listTools() async throws -> [WorkspaceToolDefinition]
    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> ToolResult
    func isRunning() async -> Bool
    func shutdown() async
}

final class MCPWorkspaceFactory: WorkspaceFactory, Sendable {
    private let providers = Mutex<[UUID: MCPWorkspaceProvider]>([:])

    func register(_ provider: MCPWorkspaceProvider) {
        providers.withLock { $0[provider.reference.id] = provider }
    }

    func remove(workspaceID: UUID) async {
        let provider = providers.withLock { $0.removeValue(forKey: workspaceID) }
        await provider?.shutdown()
    }

    func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        guard let provider = providers.withLock({ $0[reference.id] }) else {
            throw WorkspaceError.workspaceNotFound
        }
        return provider
    }
}

actor MCPWorkspaceProvider: WorkspaceToolProvider {
    nonisolated let reference: WorkspaceReference
    private let client: any MCPClient

    init(reference: WorkspaceReference, client: any MCPClient) {
        self.reference = reference
        self.client = client
    }

    var isHealthy: Bool { get async { await client.isRunning() } }

    func listTools() async throws -> [ToolReference] {
        try await client.listTools().map(ToolReference.custom)
    }

    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        do {
            return try await client.callTool(name: id, arguments: parameters)
        } catch {
            return .failure("MCP tool '\(id)' failed: \(error)")
        }
    }

    func shutdown() async {
        await client.shutdown()
    }
}

actor MCPStdioClient: MCPClient {
    private struct ErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    private struct Response: Decodable {
        let id: Int?
        let result: ACPValue?
        let error: ErrorPayload?
    }

    private struct ToolList: Decodable {
        let tools: [Tool]
        let nextCursor: String?
    }

    private struct Tool: Decodable {
        let name: String
        let description: String?
        let inputSchema: [String: AnyCodable]?
    }

    private struct CallResult: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }

        let content: [Content]?
        let isError: Bool?
    }

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let readerContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1
    private var closed = false
    private var pending: [Int: CheckedContinuation<ACPValue?, any Error>] = [:]

    init(server: ACPMcpServer) throws {
        guard case let .stdio(_, command, args, environment, _) = server else {
            throw MCPClientError.unsupportedTransport
        }
        let process = Process()
        process.executableURL = try Self.executableURL(command)
        process.arguments = args ?? []
        let parentEnvironment = ProcessInfo.processInfo.environment
        var childEnvironment = [
            "HOME": parentEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": parentEnvironment["PATH"] ?? "/usr/bin:/bin",
        ]
        for variable in environment ?? [] {
            childEnvironment[variable.name] = variable.value
        }
        process.environment = childEnvironment
        let childInput = Pipe()
        let childOutput = Pipe()
        process.standardInput = childInput
        process.standardOutput = childOutput
        process.standardError = FileHandle.nullDevice
        try process.run()
        let (readStream, readContinuation) = AsyncStream<Data>.makeStream()
        self.process = process
        input = childInput.fileHandleForWriting
        output = childOutput.fileHandleForReading
        readerContinuation = readContinuation
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                readContinuation.finish()
            } else {
                readContinuation.yield(data)
            }
        }
        Task { await self.consume(readStream) }
    }

    func initialize() async throws -> [WorkspaceToolDefinition] {
        let result = try await request(method: "initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("gnostic-pk-runtime"),
                "version": .string("0.5.0"),
            ]),
        ]))
        guard result != nil else { throw MCPClientError.missingResult }
        try notify(method: "notifications/initialized")
        return try await listTools()
    }

    func listTools() async throws -> [WorkspaceToolDefinition] {
        var cursor: String?
        var seenCursors: Set<String> = []
        var discovered: [Tool] = []
        repeat {
            var params: [String: ACPValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            guard let page = try await request(method: "tools/list", params: .object(params)) else {
                throw MCPClientError.missingResult
            }
            let data = try JSONEncoder().encode(page)
            let result = try JSONDecoder().decode(ToolList.self, from: data)
            discovered.append(contentsOf: result.tools)
            cursor = result.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw MCPClientError.repeatedCursor(cursor)
            }
        } while cursor != nil
        return discovered.map { tool in
            WorkspaceToolDefinition(
                id: tool.name,
                name: tool.name,
                description: tool.description ?? "MCP tool \(tool.name)",
                parametersSchema: tool.inputSchema ?? [:]
            )
        }
    }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        let argumentsData = try JSONEncoder().encode(arguments)
        let encodedArguments = try JSONDecoder().decode(ACPValue.self, from: argumentsData)
        let resultValue = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": encodedArguments,
        ]))
        guard let resultValue else { throw MCPClientError.missingResult }
        let result = try JSONDecoder().decode(CallResult.self, from: JSONEncoder().encode(resultValue))
        let text = (result.content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        if result.isError == true { return .failure(text.isEmpty ? "MCP tool returned an error." : text) }
        return .success(text)
    }

    func isRunning() async -> Bool { !closed && process.isRunning }

    func shutdown() async {
        guard !closed else { return }
        closed = true
        readerContinuation.finish()
        output.readabilityHandler = nil
        try? input.close()
        try? output.close()
        failPending(with: MCPClientError.closed)
        if process.isRunning { process.terminate() }
    }

    private func request(method: String, params: ACPValue) async throws -> ACPValue? {
        let id = nextID
        nextID += 1
        let request = ACPValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ])
        return try await withThrowingTaskGroup(of: ACPValue?.self) { group in
            group.addTask { try await self.sendAndWait(id: id, request: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(mcpRequestTimeoutSeconds))
                throw MCPClientError.timeout
            }
            guard let result = try await group.next() else { throw MCPClientError.closed }
            group.cancelAll()
            return result
        }
    }

    private func sendAndWait(id: Int, request: ACPValue) async throws -> ACPValue? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(request)
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelPending(id: id) }
        }
    }

    private func notify(method: String) throws {
        try write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]))
    }

    private func write(_ value: ACPValue) throws {
        guard !closed else { throw MCPClientError.closed }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(line: String) {
        guard let data = line.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard let id = response.id, let continuation = pending.removeValue(forKey: id) else { return }
            if let error = response.error {
                continuation.resume(throwing: MCPClientError.remote(code: error.code, message: error.message))
            } else {
                continuation.resume(returning: response.result)
            }
        } catch {
            failPending(with: error)
        }
    }

    private func consume(_ stream: AsyncStream<Data>) async {
        var buffer = Data()
        for await chunk in stream {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                receive(line: line)
            }
        }
        if !buffer.isEmpty {
            receive(line: String(decoding: buffer, as: UTF8.self))
        }
        failPending(with: MCPClientError.closed)
    }

    private func cancelPending(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func failPending(with error: any Error) {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private static func executableURL(_ command: String) throws -> URL {
        if command.hasPrefix("/") { return URL(fileURLWithPath: command) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw MCPClientError.executableNotFound(command)
    }
}

actor MCPHTTPClient: MCPClient {
    private struct ErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    private struct Response: Decodable {
        let id: Int?
        let result: ACPValue?
        let error: ErrorPayload?
    }

    private struct InitializeResult: Decodable {
        let protocolVersion: String
    }

    private struct ToolList: Decodable {
        let tools: [Tool]
        let nextCursor: String?
    }

    private struct Tool: Decodable {
        let name: String
        let description: String?
        let inputSchema: [String: AnyCodable]?
    }

    private struct CallResult: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }

        let content: [Content]?
        let isError: Bool?
    }

    private let url: URL
    private let headers: [String: String]
    private var protocolVersion: String?
    private var nextID = 1
    private var closed = false

    init(server: ACPMcpServer) throws {
        guard case let .http(_, rawURL, configuredHeaders, _) = server,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            throw MCPClientError.invalidURL
        }
        self.url = url
        headers = Dictionary(
            (configuredHeaders ?? []).map { ($0.name.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func initialize() async throws -> [WorkspaceToolDefinition] {
        let response = try await request(method: "initialize", params: .object([
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("gnostic-pk-runtime"),
                "version": .string("0.5.0"),
            ]),
        ]), isInitialize: true)
        guard let response else { throw MCPClientError.missingResult }
        let result = try JSONDecoder().decode(InitializeResult.self, from: JSONEncoder().encode(response))
        guard ["2025-03-26", "2025-06-18", "2025-11-25"].contains(result.protocolVersion) else {
            throw MCPClientError.unsupportedProtocolVersion(result.protocolVersion)
        }
        protocolVersion = result.protocolVersion
        try await notify(method: "notifications/initialized")
        return try await listTools()
    }

    func listTools() async throws -> [WorkspaceToolDefinition] {
        var cursor: String?
        var seenCursors: Set<String> = []
        var discovered: [Tool] = []
        repeat {
            var params: [String: ACPValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            guard let page = try await request(method: "tools/list", params: .object(params)) else {
                throw MCPClientError.missingResult
            }
            let data = try JSONEncoder().encode(page)
            let result = try JSONDecoder().decode(ToolList.self, from: data)
            discovered.append(contentsOf: result.tools)
            cursor = result.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw MCPClientError.repeatedCursor(cursor)
            }
        } while cursor != nil

        return discovered.map { tool in
            WorkspaceToolDefinition(
                id: tool.name,
                name: tool.name,
                description: tool.description ?? "MCP tool \(tool.name)",
                parametersSchema: tool.inputSchema ?? [:]
            )
        }
    }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        let data = try JSONEncoder().encode(arguments)
        let encodedArguments = try JSONDecoder().decode(ACPValue.self, from: data)
        guard let resultValue = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": encodedArguments,
        ])) else {
            throw MCPClientError.missingResult
        }
        let result = try JSONDecoder().decode(CallResult.self, from: JSONEncoder().encode(resultValue))
        let text = (result.content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        if result.isError == true { return .failure(text.isEmpty ? "MCP tool returned an error." : text) }
        return .success(text)
    }

    func shutdown() async {
        closed = true
    }

    func isRunning() async -> Bool { !closed }

    private func request(method: String, params: ACPValue, isInitialize: Bool = false) async throws -> ACPValue? {
        let id = nextID
        nextID += 1
        var request = URLRequest(url: url, timeoutInterval: mcpRequestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !isInitialize, let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONEncoder().encode(ACPJSONRPCRequest(
            id: .int(id),
            method: method,
            params: params
        ))
        let (data, rawResponse) = try await URLSession.shared.data(for: request)
        guard !closed else { throw MCPClientError.closed }
        guard let response = rawResponse as? HTTPURLResponse else { throw MCPClientError.invalidHTTPResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw MCPClientError.httpStatus(response.statusCode)
        }
        let message = try JSONDecoder().decode(Response.self, from: data)
        guard message.id == id else { throw MCPClientError.responseMismatch }
        if let error = message.error { throw MCPClientError.remote(code: error.code, message: error.message) }
        return message.result
    }

    private func notify(method: String) async throws {
        var request = URLRequest(url: url, timeoutInterval: mcpRequestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONEncoder().encode(ACPJSONRPCNotification(method: method))
        let (_, rawResponse) = try await URLSession.shared.data(for: request)
        guard !closed else { throw MCPClientError.closed }
        guard let response = rawResponse as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw MCPClientError.invalidHTTPResponse
        }
    }
}

enum MCPClientFactory {
    static func make(server: ACPMcpServer) throws -> any MCPClient {
        switch server {
        case .stdio: try MCPStdioClient(server: server)
        case .http: try MCPHTTPClient(server: server)
        case .other: throw MCPClientError.unsupportedTransport
        }
    }
}

enum MCPClientError: Error {
    case unsupportedTransport
    case invalidURL
    case invalidHTTPResponse
    case responseMismatch
    case missingResult
    case closed
    case timeout
    case httpStatus(Int)
    case unsupportedProtocolVersion(String)
    case executableNotFound(String)
    case repeatedCursor(String)
    case remote(code: Int, message: String)
}
