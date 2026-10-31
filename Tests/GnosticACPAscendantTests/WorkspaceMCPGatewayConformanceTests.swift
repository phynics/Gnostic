// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import GnosticACPAscendant
@_spi(RuntimeHost) import GnosticCore
import GnosticProtocol
import Testing

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

    /// Runs a state change while the approval prompt is pending, then approves.
    private actor ChangingPermissionService: AscendantBackendPermissionService {
        private let change: @MainActor @Sendable () -> Void

        init(change: @escaping @MainActor @Sendable () -> Void) {
            self.change = change
        }

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            await change()
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
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
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

    private static func searchTool(requiresPermission: Bool = false, schema: ManifestJSONValue? = nil) -> BackendWorkspaceTool {
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

    private func manifestValue(_ value: ACPValue?) throws -> ManifestJSONValue {
        let value = try #require(value)
        return try JSONDecoder().decode(ManifestJSONValue.self, from: JSONEncoder().encode(value))
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
        let schema: ManifestJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("query"), .string("target")]),
            "additionalProperties": .bool(false),
            "properties": .object([
                "query": .object(["type": .string("string"), "minLength": .number(1)]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "default": .number(20)]),
                "ratio": .object(["type": .string("number"), "maximum": .number(0.5)]),
                "nullable": .object(["type": .array([.string("string"), .string("null")]), "default": .null]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "target": .object([
                    "oneOf": .array([
                        .object([
                            "type": .string("object"),
                            "required": .array([.string("kind"), .string("path")]),
                            "properties": .object([
                                "kind": .object(["const": .string("file")]),
                                "path": .object(["type": .string("string")]),
                            ]),
                        ]),
                        .object([
                            "type": .string("object"),
                            "required": .array([.string("kind"), .string("uri")]),
                            "properties": .object([
                                "kind": .object(["const": .string("remote")]),
                                "uri": .object(["type": .string("string"), "format": .string("uri")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            "x-provider-extension": .object(["cost": .number(3), "stable": .bool(true)]),
        ])
        let fixture = try makeFixture(tools: [Self.searchTool(schema: schema)])
        defer { fixture.gateway.stop() }

        let tool = try #require(try await fixture.listedTools()[fixture.toolName])

        #expect(try manifestValue(tool["inputSchema"]) == schema)
    }

    @Test("an absent schema is advertised as an unconstrained object, and a schema without a type becomes an object")
    @MainActor
    func absentAndUntypedSchemas() async throws {
        let untyped: ManifestJSONValue = .object(["properties": .object(["query": .object(["type": .string("string")])])])
        let fixture = try makeFixture(tools: [
            Self.searchTool(),
            BackendWorkspaceTool(id: "untyped", name: "Untyped", description: "No type", parametersSchema: untyped),
        ])
        defer { fixture.gateway.stop() }

        let tools = try await fixture.listedTools()

        #expect(try manifestValue(tools[fixture.toolName]?["inputSchema"]) == .object(["type": .string("object")]))
        #expect(try manifestValue(tools[fixture.toolName(for: "untyped")]?["inputSchema"]) == .object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
        ]))
    }

    @Test("the gateway does not validate arguments against the schema: they reach the provider, and its failure is a tool result")
    @MainActor
    func gatewayForwardsArgumentsWithoutSchemaValidation() async throws {
        let schema: ManifestJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("query")]),
            "properties": .object(["query": .object(["type": .string("string")])]),
        ])
        let fixture = try makeFixture(tools: [Self.searchTool(schema: schema)])
        defer { fixture.gateway.stop() }
        fixture.service.outcome = .success(BackendWorkspaceResult(message: "query is required", isSuccess: false))

        let reply = try await fixture.call(arguments: .object([
            "nested": .object(["list": .array([.int(1), .double(1.5), .bool(true), .null, .string("text")])]),
        ]))

        #expect(fixture.service.invocations.first?.arguments == [
            "nested": .object(["list": .array([.number(1), .number(1.5), .bool(true), .null, .string("text")])]),
        ])
        let fields = try resultFields(reply.message)
        #expect(fields["isError"] == .bool(true))
        #expect(resultText(fields) == "query is required")
    }

    // MARK: Results and protocol errors

    @Test("a structured success returns text and structured content without an error")
    @MainActor
    func structuredSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.gateway.stop() }
        let value: ManifestJSONValue = .object(["count": .number(2), "items": .array([.string("a"), .string("b")])])
        fixture.service.outcome = .success(BackendWorkspaceResult(value: value))

        let reply = try await fixture.call()

        #expect(reply.status == 200)
        let fields = try resultFields(reply.message)
        #expect(fields["isError"] == .bool(false))
        #expect(try manifestValue(fields["structuredContent"]) == value)
        let text = try #require(resultText(fields))
        #expect(try JSONDecoder().decode(ManifestJSONValue.self, from: Data(text.utf8)) == value)
    }

    @Test(
        "a non-object tool value stays in text content because MCP structured content must be an object",
        arguments: [
            ManifestJSONValue.string("plain text"),
            .array([.string("a"), .string("b")]),
            .number(3),
            .bool(true),
        ]
    )
    @MainActor
    func nonObjectValuesAreNotStructuredContent(value: ManifestJSONValue) async throws {
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
        turn: MutableTurn
    ) throws -> (gateway: WorkspaceMCPGateway, endpoint: URL, authorization: String) {
        let gateway = WorkspaceMCPGateway(
            timelineID: timelineID,
            timelineRegistry: registry,
            workspaceService: service,
            permissionService: permission,
            timelineJournalRecorder: journals.map { TimelineJournalRecorder(journals: $0) },
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
        turn: MutableTurn
    ) throws -> Fixture {
        base.gateway.stop()
        let started = try startGateway(
            service: base.service,
            registry: base.registry,
            timelineID: base.timelineID,
            permission: permission,
            journals: journals,
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
            authorization: started.authorization
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
        let fixture = try rewire(base, permission: ChangingPermissionService {
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
        let fixture = try rewire(base, permission: ChangingPermissionService {
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
        let fixture = try rewire(base, permission: ChangingPermissionService {
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
