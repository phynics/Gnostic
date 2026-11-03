// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GnosticACPAscendant
import GnosticACPWire
@_spi(RuntimeHost) import GnosticCore
import GnosticProtocol
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Exercises the Workspace MCP gateway at its authenticated HTTP seam.
///
/// These cases separate three outcomes that a Runtime must be able to tell
/// apart: a JSON-RPC protocol error, a successful call whose tool reports a
/// failure, and a successful call with a result.
@Suite("Workspace MCP gateway conformance", .serialized)
struct WorkspaceMCPGatewayConformanceTests {
    private actor RecordingPermissionService: AscendantBackendPermissionService {
        let decision: AscendantPermissionDecision
        private(set) var requests: [BackendPermissionRequest] = []

        init(decision: AscendantPermissionDecision) {
            self.decision = decision
        }

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            requests.append(request)
            return decision
        }
    }

    /// The steps a gateway call has reached, for the report of a call that does not finish.
    private final class PhaseLog: @unchecked Sendable { // SAFETY: Every access holds the lock.
        private let lock = NSLock()
        private var entries: [String] = []

        func note(_ phase: String) {
            lock.withLock { entries.append(phase) }
        }

        var report: String {
            lock.withLock { entries.isEmpty ? "no phase reached" : entries.joined(separator: " -> ") }
        }
    }

    /// Runs a state change while the approval prompt is pending, then approves.
    private actor ChangingPermissionService: AscendantBackendPermissionService {
        private let change: @MainActor @Sendable () -> Void
        private let phases: PhaseLog?

        init(phases: PhaseLog? = nil, change: @escaping @MainActor @Sendable () -> Void) {
            self.phases = phases
            self.change = change
        }

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            phases?.note("approval requested")
            await change()
            phases?.note("state change applied")
            return .approved
        }
    }

    private struct ProviderOffline: LocalizedError {
        var errorDescription: String? { "provider is offline" }
    }

    @MainActor
    private final class ScriptedWorkspaceService: AscendantBackendWorkspaceService {
        var workspaceReference: BackendWorkspaceReference
        var outcome: Result<BackendWorkspaceResult, any Error> = .success(.success("workspace result"))
        private(set) var invocations: [BackendWorkspaceInvocation] = []

        init(workspaceReference: BackendWorkspaceReference) {
            self.workspaceReference = workspaceReference
        }

        func reference(id: UUID) async -> BackendWorkspaceReference? {
            id == workspaceReference.id ? workspaceReference : nil
        }

        func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
            invocations.append(invocation)
            return try outcome.get()
        }
    }

    /// One started gateway with an attached Workspace.
    @MainActor
    private struct Fixture {
        let workspaceID: UUID
        let timelineID: UUID
        let registry: AscendantTimelineRegistry
        let service: ScriptedWorkspaceService
        let permission: RecordingPermissionService
        let gateway: WorkspaceMCPGateway
        let endpoint: URL
        let authorization: String
        var phases = PhaseLog()

        var toolName: String { toolName(for: "search") }

        func toolName(for toolID: String) -> String {
            "workspace_\(workspaceID.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))__\(toolID)"
        }

        func reference(
            status: BackendWorkspaceStatus = .available,
            tools: [BackendWorkspaceTool]
        ) -> BackendWorkspaceReference {
            BackendWorkspaceReference(id: workspaceID, uri: "workspace://gateway-conformance", status: status, tools: tools)
        }

        func send(method: String, params: [String: ACPValue]) async throws -> (status: Int, message: ACPJSONRPCResponse?) {
            let body = try JSONEncoder().encode(ACPJSONRPCRequest(id: .string("test"), method: method, params: .object(params)))
            return try await post(body)
        }

        func post(_ body: Data) async throws -> (status: Int, message: ACPJSONRPCResponse?) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.httpBody = body
            // A request that is only slow fails at `timeoutInterval` with an error. The
            // watchdog is for a call that never returns even then, such as a blocked
            // main thread. A Dispatch timer does not depend on the Swift task pool or the
            // main actor, so it can still report and end the run instead of holding the job.
            let phases = phases
            let watchdog = DispatchWorkItem {
                let report = "Gateway call did not finish within 60 s. Phases: \(phases.report)"
                FileHandle.standardError.write(Data((report + "\n").utf8))
                Issue.record(Comment(rawValue: report))
                fatalError(report)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
            defer { watchdog.cancel() }
            phases.note("request sent")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            phases.note("reply received")
            let status = try #require(response as? HTTPURLResponse).statusCode
            return (status, try? JSONDecoder().decode(ACPJSONRPCResponse.self, from: data))
        }

        func call(_ name: String? = nil, arguments: ACPValue? = .object([:])) async throws -> (status: Int, message: ACPJSONRPCResponse?) {
            var params: [String: ACPValue] = ["name": .string(name ?? toolName)]
            if let arguments { params["arguments"] = arguments }
            return try await send(method: "tools/call", params: params)
        }

        func listedTools() async throws -> [String: [String: ACPValue]] {
            let listed = try await send(method: "tools/list", params: [:])
            guard case let .object(result)? = listed.message?.result,
                  case let .array(tools)? = result["tools"] else {
                Issue.record("tools/list must return a tool array.")
                return [:]
            }
            var byName: [String: [String: ACPValue]] = [:]
            for case let .object(tool) in tools {
                if case let .string(name)? = tool["name"] { byName[name] = tool }
            }
            return byName
        }
    }

    private static func searchTool(requiresPermission: Bool = false, schema: GnosticJSONValue? = nil) -> BackendWorkspaceTool {
        BackendWorkspaceTool(
            id: "search",
            name: "Search",
            description: "Search workspace records",
            parametersSchema: schema,
            requiresPermission: requiresPermission
        )
    }

    @MainActor
    private func makeFixture(
        tools: [BackendWorkspaceTool] = [Self.searchTool()],
        decision: AscendantPermissionDecision = .approved
    ) throws -> Fixture {
        let ascendantID = UUID()
        let timelineID = UUID()
        let workspaceID = UUID()
        let service = ScriptedWorkspaceService(workspaceReference: BackendWorkspaceReference(
            id: workspaceID,
            uri: "workspace://gateway-conformance",
            status: .available,
            tools: tools
        ))
        let registry = AscendantTimelineRegistry(
            ascendantID: ascendantID,
            privateTimelineID: timelineID,
            configured: [.init(
                id: timelineID,
                title: "Gateway conformance",
                operatingAscendantID: ascendantID,
                attachments: [.local(workspaceID)]
            )],
            remote: .init(ensure: { _, _ in }, rename: { _, _ in }, delete: { _ in })
        )
        let permission = RecordingPermissionService(decision: decision)
        let gateway = WorkspaceMCPGateway(
            timelineID: timelineID,
            timelineRegistry: registry,
            workspaceService: service,
            permissionService: permission,
            activeTurn: { _ in ("turn-1", "session-1") }
        )
        guard case let .http(_, endpoint, headers, _) = try gateway.start(),
              let url = URL(string: endpoint),
              let authorization = headers?.first(where: { $0.name == "Authorization" })?.value else {
            throw ProviderOffline()
        }
        return Fixture(
            workspaceID: workspaceID,
            timelineID: timelineID,
            registry: registry,
            service: service,
            permission: permission,
            gateway: gateway,
            endpoint: url,
            authorization: authorization
        )
    }

    private func manifestValue(_ value: ACPValue?) throws -> GnosticJSONValue {
        let value = try #require(value)
        return try JSONDecoder().decode(GnosticJSONValue.self, from: JSONEncoder().encode(value))
    }

    private func resultFields(_ message: ACPJSONRPCResponse?) throws -> [String: ACPValue] {
        #expect(message?.error == nil)
        guard case let .object(fields)? = message?.result else {
            Issue.record("tools/call must return a result object.")
            return [:]
        }
        return fields
    }

    private func resultText(_ fields: [String: ACPValue]) -> String? {
        guard case let .array(content)? = fields["content"],
              case let .object(first)? = content.first,
              case let .string(text)? = first["text"] else {
            return nil
        }
        return text
    }

    // MARK: Schema fidelity

    @Test("tools/list advertises a provider schema with semantic parity")
    @MainActor
    func schemaParity() async throws {
        let schema: GnosticJSONValue = .dictionary([
            "type": .string("object"),
            "required": .array([.string("query"), .string("target")]),
            "additionalProperties": .boolean(false),
            "properties": .dictionary([
                "query": .dictionary(["type": .string("string"), "minLength": .integer(1)]),
                "limit": .dictionary(["type": .string("integer"), "minimum": .integer(1), "default": .integer(20)]),
                "ratio": .dictionary(["type": .string("number"), "maximum": .number(0.5)]),
                "nullable": .dictionary(["type": .array([.string("string"), .string("null")]), "default": .null]),
                "tags": .dictionary(["type": .string("array"), "items": .dictionary(["type": .string("string")])]),
                "target": .dictionary([
                    "oneOf": .array([
                        .dictionary([
                            "type": .string("object"),
                            "required": .array([.string("kind"), .string("path")]),
                            "properties": .dictionary([
                                "kind": .dictionary(["const": .string("file")]),
                                "path": .dictionary(["type": .string("string")]),
                            ]),
                        ]),
                        .dictionary([
                            "type": .string("object"),
                            "required": .array([.string("kind"), .string("uri")]),
                            "properties": .dictionary([
                                "kind": .dictionary(["const": .string("remote")]),
                                "uri": .dictionary(["type": .string("string"), "format": .string("uri")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            "x-provider-extension": .dictionary(["cost": .integer(3), "stable": .boolean(true)]),
        ])
        let fixture = try makeFixture(tools: [Self.searchTool(schema: schema)])
        defer { fixture.gateway.stop() }

        let tool = try #require(try await fixture.listedTools()[fixture.toolName])

        #expect(try manifestValue(tool["inputSchema"]) == schema)
    }

    @Test("an absent schema is advertised as an unconstrained object, and a schema without a type becomes an object")
    @MainActor
    func absentAndUntypedSchemas() async throws {
        let untyped: GnosticJSONValue = .dictionary(["properties": .dictionary(["query": .dictionary(["type": .string("string")])])])
        let fixture = try makeFixture(tools: [
            Self.searchTool(),
            BackendWorkspaceTool(id: "untyped", name: "Untyped", description: "No type", parametersSchema: untyped),
        ])
        defer { fixture.gateway.stop() }

        let tools = try await fixture.listedTools()

        #expect(try manifestValue(tools[fixture.toolName]?["inputSchema"]) == .dictionary(["type": .string("object")]))
        #expect(try manifestValue(tools[fixture.toolName(for: "untyped")]?["inputSchema"]) == .dictionary([
            "type": .string("object"),
            "properties": .dictionary(["query": .dictionary(["type": .string("string")])]),
        ]))
    }

    @Test("the gateway does not validate arguments against the schema: they reach the provider, and its failure is a tool result")
    @MainActor
    func gatewayForwardsArgumentsWithoutSchemaValidation() async throws {
        let schema: GnosticJSONValue = .dictionary([
            "type": .string("object"),
            "required": .array([.string("query")]),
            "properties": .dictionary(["query": .dictionary(["type": .string("string")])]),
        ])
        let fixture = try makeFixture(tools: [Self.searchTool(schema: schema)])
        defer { fixture.gateway.stop() }
        fixture.service.outcome = .success(BackendWorkspaceResult(message: "query is required", isSuccess: false))

        let reply = try await fixture.call(arguments: .object([
            "nested": .object(["list": .array([.int(1), .double(1.5), .bool(true), .null, .string("text")])]),
        ]))

        #expect(fixture.service.invocations.first?.arguments == [
            "nested": .dictionary(["list": .array([.integer(1), .number(1.5), .boolean(true), .null, .string("text")])]),
        ])
        let fields = try resultFields(reply.message)
        #expect(fields["isError"] == .bool(true))
        #expect(resultText(fields) == "query is required")
    }

    @Test("an integer argument above 2^53 reaches the provider unchanged")
    @MainActor
    func largeIntegerArgumentsStayExact() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        let beyondDouble = 9_007_199_254_740_993

        _ = try await fixture.call(arguments: .object(["id": .int(beyondDouble), "ids": .array([.int(Int.max), .int(Int.min)])]))

        #expect(fixture.service.invocations.first?.arguments == [
            "id": .integer(Int64(beyondDouble)),
            "ids": .array([.integer(Int64.max), .integer(Int64.min)]),
        ])
    }

    @Test("an unsigned integer above Int.max stays exact in arguments and in both result forms")
    @MainActor
    func unsignedIntegersStayExact() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        let value: GnosticJSONValue = .dictionary(["id": .unsignedInteger(UInt64.max)])
        fixture.service.outcome = .success(BackendWorkspaceResult(value: value))

        let reply = try await fixture.call(arguments: .object(["id": .uint(UInt64.max)]))

        #expect(fixture.service.invocations.first?.arguments == ["id": .unsignedInteger(UInt64.max)])
        let fields = try resultFields(reply.message)
        #expect(fields["structuredContent"] == .object(["id": .uint(UInt64.max)]))
        let text = try #require(resultText(fields))
        #expect(text.contains("18446744073709551615"))
        let encoded = try JSONEncoder().encode(fields["structuredContent"])
        #expect(String(decoding: encoded, as: UTF8.self).contains("18446744073709551615"))
        #expect(try JSONDecoder().decode(ACPValue.self, from: encoded) == .object(["id": .uint(UInt64.max)]))
    }

    // MARK: Results and protocol errors

    @Test("a structured success returns text and structured content without an error")
    @MainActor
    func structuredSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        let value: GnosticJSONValue = .dictionary(["count": .integer(2), "items": .array([.string("a"), .string("b")])])
        fixture.service.outcome = .success(BackendWorkspaceResult(value: value))

        let reply = try await fixture.call()

        #expect(reply.status == 200)
        let fields = try resultFields(reply.message)
        #expect(fields["isError"] == .bool(false))
        #expect(try manifestValue(fields["structuredContent"]) == value)
        let text = try #require(resultText(fields))
        #expect(try JSONDecoder().decode(GnosticJSONValue.self, from: Data(text.utf8)) == value)
    }

    @Test(
        "a non-object tool value stays in text content because MCP structured content must be an object",
        arguments: [
            GnosticJSONValue.string("plain text"),
            .array([.string("a"), .string("b")]),
            .integer(3),
            .boolean(true),
        ]
    )
    @MainActor
    func nonObjectValuesAreNotStructuredContent(value: GnosticJSONValue) async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        fixture.service.outcome = .success(BackendWorkspaceResult(value: value))

        let fields = try resultFields(try await fixture.call().message)

        #expect(fields["isError"] == .bool(false))
        #expect(fields["structuredContent"] == nil)
        #expect(resultText(fields)?.isEmpty == false)
    }

    @Test("a tool-level failure is a successful call that reports isError")
    @MainActor
    func toolLevelFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        fixture.service.outcome = .success(BackendWorkspaceResult(message: "record not found", isSuccess: false))

        let reply = try await fixture.call()

        #expect(reply.status == 200)
        let fields = try resultFields(reply.message)
        #expect(fields["isError"] == .bool(true))
        #expect(resultText(fields) == "record not found")
        #expect(fixture.service.invocations.count == 1)
    }

    @Test("a provider that goes offline during invocation is a protocol error, not a tool result")
    @MainActor
    func offlineProvider() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        fixture.service.outcome = .failure(ProviderOffline())

        let reply = try await fixture.call()

        #expect(reply.status == 200)
        #expect(reply.message?.error?.code == -32003)
        #expect(reply.message?.result == nil)
        #expect(fixture.service.invocations.count == 1)
    }

    @Test("a missing tool is a protocol error and dispatches nothing")
    @MainActor
    func missingTool() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call(fixture.toolName(for: "absent"))

        #expect(reply.message?.error?.code == -32003)
        #expect(reply.message?.result == nil)
        #expect(fixture.service.invocations.isEmpty)
    }

    // MARK: Malformed requests

    @Test("tools/call without a tool name is invalid params")
    @MainActor
    func missingToolName() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }

        let reply = try await fixture.send(method: "tools/call", params: ["arguments": .object([:])])

        #expect(reply.message?.error?.code == ACPv2Protocol.ErrorCode.invalidParams)
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test(
        "non-object arguments are invalid params before any permission prompt or dispatch",
        arguments: [
            ACPValue.string("query=needle"),
            .array([.string("needle")]),
            .int(1),
            .bool(true),
            .null,
        ]
    )
    @MainActor
    func malformedArguments(arguments: ACPValue) async throws {
        let fixture = try makeFixture(tools: [Self.searchTool(requiresPermission: true)])
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call(arguments: arguments)

        #expect(reply.message?.error?.code == ACPv2Protocol.ErrorCode.invalidParams)
        #expect(reply.message?.result == nil)
        #expect(fixture.service.invocations.isEmpty)
        #expect(await fixture.permission.requests.isEmpty)
    }

    @Test("omitted arguments dispatch as an empty object")
    @MainActor
    func omittedArguments() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call(arguments: nil)

        #expect(reply.message?.error == nil)
        #expect(fixture.service.invocations.first?.arguments == [:])
    }

    @Test("a body that is not JSON-RPC is rejected at HTTP and dispatches nothing")
    @MainActor
    func malformedBody() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }

        let reply = try await fixture.post(Data("{not json".utf8))

        #expect(reply.status == 400)
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test("a body past the nesting bound, or in UTF-16, is rejected at HTTP and dispatches nothing")
    @MainActor
    func unsafeBodies() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }

        // The envelope and `params` take two levels.
        func body(depth: Int, prefix: String = "") -> String {
            #"{\#(prefix)"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"deep":"#
                + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}}"
        }
        let bound = JSONNesting.maximumDecodedDepth
        let atBound = try await fixture.post(Data(body(depth: bound - 2).utf8))
        #expect(atBound.status != 400)

        for unsafe in [
            Data(body(depth: bound - 1).utf8),
            Data(body(depth: 100_000).utf8),
            Data(body(depth: 200, prefix: #""a":"\"","#).utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
        ] {
            let reply = try await fixture.post(unsafe)
            #expect(reply.status == 400)
        }
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test("an unknown MCP method is method not found")
    @MainActor
    func unknownMethod() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }

        let reply = try await fixture.send(method: "resources/list", params: [:])

        #expect(reply.message?.error?.code == ACPv2Protocol.ErrorCode.methodNotFound)
    }

    // MARK: Authorization changes after tools/list

    @Test("a stale handle fails after its attachment is revoked and works again only after reattachment")
    @MainActor
    func revokedAttachmentAfterListing() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        #expect(try await fixture.listedTools()[fixture.toolName] != nil)

        fixture.registry.detachWorkspace(fixture.workspaceID, from: fixture.timelineID)

        #expect(try await fixture.listedTools().isEmpty)
        let revoked = try await fixture.call()
        #expect(revoked.message?.error?.code == -32003)
        #expect(fixture.service.invocations.isEmpty)

        try fixture.registry.attachWorkspace(fixture.workspaceID, to: fixture.timelineID)
        let restored = try await fixture.call()
        #expect(restored.message?.error == nil)
        #expect(fixture.service.invocations.count == 1)
    }

    @Test("a tool removed by its provider after tools/list fails closed")
    @MainActor
    func toolRemovedAfterListing() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        #expect(try await fixture.listedTools()[fixture.toolName] != nil)

        fixture.service.workspaceReference = fixture.reference(tools: [])
        let reply = try await fixture.call()

        #expect(reply.message?.error?.code == -32003)
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test("a Workspace that goes offline after tools/list fails closed")
    @MainActor
    func workspaceOfflineAfterListing() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        #expect(try await fixture.listedTools()[fixture.toolName] != nil)

        fixture.service.workspaceReference = fixture.reference(status: .unavailable, tools: [Self.searchTool()])
        let reply = try await fixture.call()

        #expect(reply.message?.error?.code == -32003)
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test("a connection that sends nothing does not block later requests")
    @MainActor
    func stalledConnectionDoesNotBlockLaterRequests() async throws {
        let base = try makeFixture()
        let fixture = try rewire(
            base, permission: base.permission, connectionTimeout: 1, turn: MutableTurn()
        )
        defer { fixture.gateway.stop() }
        let stalled = try openIdleConnection(to: fixture.endpoint)
        defer { close(stalled) }

        // The gateway serves one connection at a time, so it must give up on a
        // client that sends nothing. Without a bound, this request waits behind it.
        #expect(try await fixture.listedTools()[fixture.toolName] != nil)
    }

    private func openIdleConnection(to endpoint: URL) throws -> Int32 {
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw ProviderOffline() }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(try #require(endpoint.port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw ProviderOffline()
        }
        return descriptor
    }

    @Test("a Workspace whose tools resolve after the Session started becomes listed and callable")
    @MainActor
    func toolsResolvedAfterSessionStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        let toolName = fixture.toolName
        // The attachment survived a restart; its tool pages have not arrived.
        fixture.service.workspaceReference = fixture.reference(status: .unavailable, tools: [])

        #expect(try await fixture.listedTools().isEmpty)
        let early = try await fixture.call()
        #expect(early.message?.error?.code == -32003)
        #expect(early.message?.error?.message.contains(fixture.workspaceID.uuidString) == true)
        #expect(early.message?.error?.message.contains("attached but unavailable") == true)
        #expect(fixture.service.invocations.isEmpty)

        // Resolution completes while the same gateway, and so the same Session, is live.
        fixture.service.workspaceReference = fixture.reference(tools: [Self.searchTool()])

        #expect(try await fixture.listedTools()[toolName] != nil)
        let late = try await fixture.call()
        #expect(late.message?.error == nil)
        #expect(fixture.service.invocations.count == 1)
    }

    @Test("a permission requirement added after tools/list applies to the next call")
    @MainActor
    func permissionAddedAfterListing() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        #expect(try await fixture.listedTools()[fixture.toolName] != nil)
        #expect(await fixture.permission.requests.isEmpty)

        fixture.service.workspaceReference = fixture.reference(tools: [Self.searchTool(requiresPermission: true)])
        let reply = try await fixture.call()

        #expect(reply.message?.error == nil)
        #expect(await fixture.permission.requests.count == 1)
        #expect(fixture.service.invocations.first?.permissionApproved == true)
    }

    @Test(
        "an unapproved permission is a protocol error and never invokes the tool",
        arguments: [AscendantPermissionDecision.denied, .unavailable(reason: "hostUnavailable")]
    )
    @MainActor
    func unapprovedPermission(decision: AscendantPermissionDecision) async throws {
        let fixture = try makeFixture(tools: [Self.searchTool(requiresPermission: true)], decision: decision)
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call()

        #expect(reply.message?.error?.code == -32003)
        #expect(reply.message?.result == nil)
        #expect(await fixture.permission.requests.count == 1)
        #expect(fixture.service.invocations.isEmpty)
    }

    // MARK: Changes during a call

    @MainActor
    private final class MutableTurn {
        var current: (clientTurnID: String, sessionID: String)? = ("turn-1", "session-1")
    }

    @MainActor
    private func startGateway(
        service: ScriptedWorkspaceService,
        registry: AscendantTimelineRegistry,
        timelineID: UUID,
        permission: any AscendantBackendPermissionService,
        journals: TimelineJournalStore? = nil,
        connectionTimeout: TimeInterval = 10,
        turn: MutableTurn
    ) throws -> (gateway: WorkspaceMCPGateway, endpoint: URL, authorization: String) {
        let gateway = WorkspaceMCPGateway(
            timelineID: timelineID,
            timelineRegistry: registry,
            workspaceService: service,
            permissionService: permission,
            timelineJournalRecorder: journals.map { TimelineJournalRecorder(journals: $0) },
            connectionTimeout: connectionTimeout,
            activeTurn: { _ in turn.current }
        )
        guard case let .http(_, endpoint, headers, _) = try gateway.start(),
              let url = URL(string: endpoint),
              let authorization = headers?.first(where: { $0.name == "Authorization" })?.value else {
            throw ProviderOffline()
        }
        return (gateway, url, authorization)
    }

    @MainActor
    private func rewire(
        _ base: Fixture,
        permission: any AscendantBackendPermissionService,
        journals: TimelineJournalStore? = nil,
        connectionTimeout: TimeInterval = 10,
        turn: MutableTurn
    ) throws -> Fixture {
        base.gateway.stop()
        let started = try startGateway(
            service: base.service,
            registry: base.registry,
            timelineID: base.timelineID,
            permission: permission,
            journals: journals,
            connectionTimeout: connectionTimeout,
            turn: turn
        )
        return Fixture(
            workspaceID: base.workspaceID,
            timelineID: base.timelineID,
            registry: base.registry,
            service: base.service,
            permission: base.permission,
            gateway: started.gateway,
            endpoint: started.endpoint,
            authorization: started.authorization,
            phases: base.phases
        )
    }

    @Test("an attachment revoked while approval is pending stops the dispatch")
    @MainActor
    func attachmentRevokedDuringApproval() async throws {
        let base = try makeFixture(tools: [Self.searchTool(requiresPermission: true)])
        let turn = MutableTurn()
        let registry = base.registry
        let workspaceID = base.workspaceID
        let timelineID = base.timelineID
        let fixture = try rewire(base, permission: ChangingPermissionService(phases: base.phases) {
            registry.detachWorkspace(workspaceID, from: timelineID)
        }, turn: turn)
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call()

        #expect(reply.message?.error?.code == -32003)
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test("a Workspace that goes offline while approval is pending stops the dispatch")
    @MainActor
    func workspaceOfflineDuringApproval() async throws {
        let base = try makeFixture(tools: [Self.searchTool(requiresPermission: true)])
        let turn = MutableTurn()
        let service = base.service
        let offline = base.reference(status: .unavailable, tools: [Self.searchTool(requiresPermission: true)])
        let fixture = try rewire(base, permission: ChangingPermissionService(phases: base.phases) {
            service.workspaceReference = offline
        }, turn: turn)
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call()

        #expect(reply.message?.error?.code == -32003)
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test("an approval granted to a Turn that has since ended does not authorize the call")
    @MainActor
    func turnEndedDuringApproval() async throws {
        let base = try makeFixture(tools: [Self.searchTool(requiresPermission: true)])
        let turn = MutableTurn()
        let fixture = try rewire(base, permission: ChangingPermissionService(phases: base.phases) {
            turn.current = ("turn-2", "session-1")
        }, turn: turn)
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call()

        #expect(reply.message?.error?.code == -32003)
        #expect(fixture.service.invocations.isEmpty)
    }

    @Test("the gateway journals an unavailable decision as unavailable, not as a denial")
    @MainActor
    func gatewayJournalsUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelineJournalStore(directoryURL: directory)
        let base = try makeFixture(tools: [Self.searchTool(requiresPermission: true)])
        let fixture = try rewire(
            base,
            permission: RecordingPermissionService(decision: .unavailable(reason: "hostUnavailable")),
            journals: store,
            turn: MutableTurn()
        )
        defer { fixture.gateway.stop() }

        let reply = try await fixture.call()

        #expect(reply.message?.error?.code == -32003)
        let records = try await store.journal(for: fixture.timelineID).replay()
        let decisions = records.compactMap { record -> String? in
            if case let .permissionDecision(_, _, decision, approved) = record.payload, !approved {
                return decision
            }
            return nil
        }
        #expect(decisions == ["unavailable"])
    }
}
