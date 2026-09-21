// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticLettaBackend
import GnosticLettaTestSupport
import Testing

/// Collects backend updates so a test can assert what a client would observe.
private actor UpdateRecorder: AscendantBackendUpdateSink {
    private(set) var updates: [AscendantBackendUpdate] = []

    func append(_ update: AscendantBackendUpdate) async throws {
        updates.append(update)
    }

    var kinds: [String] { updates.map(\.kind) }
    var terminal: Bool { updates.contains { $0.terminal } }
    var text: String { updates.compactMap(\.text).joined() }
}

/// A host permission service with a fixed decision.
private actor StubPermissionService: AscendantBackendPermissionService {
    let decision: AscendantPermissionDecision
    private(set) var requestCount = 0

    init(decision: AscendantPermissionDecision) {
        self.decision = decision
    }

    func requestApproval(for _: BackendPermissionRequest) async -> AscendantPermissionDecision {
        requestCount += 1
        return decision
    }
}

/// A host Workspace service backed by one advertised tool.
@MainActor
private final class StubWorkspaceService: AscendantBackendWorkspaceService {
    let reference: BackendWorkspaceReference
    let result: BackendWorkspaceResult
    private(set) var invocations: [BackendWorkspaceInvocation] = []

    init(reference: BackendWorkspaceReference, result: BackendWorkspaceResult) {
        self.reference = reference
        self.result = result
    }

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        id == reference.id ? reference : nil
    }

    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        invocations.append(invocation)
        return result
    }
}

@Suite("Letta Ascendant backend", .serialized)
struct LettaAscendantBackendTests {
    private let serverSettings: [String: ManifestJSONValue] = [
        "serverURL": .string("http://127.0.0.1:8283"),
        "model": .string("openai/test-model"),
    ]
    private let apiKey = "fixture-key"

    private struct Fixture {
        let backend: LettaAscendantBackend
        let transport: FixtureLettaTransport
        let ascendantID: UUID
        let timelineID: UUID
    }

    @MainActor
    private func makeFixture(
        script: @escaping @Sendable (String) -> LettaFixtureScript = { .plain("reply: \($0)") },
        attachments: [UUID] = [],
        workspace: (any AscendantBackendWorkspaceService)? = nil,
        permission: any AscendantBackendPermissionService = StubPermissionService(decision: .approved)
    ) throws -> Fixture {
        let transport = FixtureLettaTransport(scriptForMessage: script)
        let ascendantID = UUID()
        let timelineID = UUID()
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "Letta Ascendant",
            defaultTimelineID: timelineID,
            backend: .init(
                kind: LettaAscendantBackend.kind,
                settings: serverSettings,
                secrets: ["apiKey": .string(apiKey)]
            )
        )
        let timelines = [NodeManifest.Timeline(
            id: timelineID,
            title: "Default",
            operatingAscendantID: ascendantID,
            attachments: attachments.map(NodeManifest.WorkspaceAttachment.local)
        )]
        let backend = try LettaAscendantBackend(
            ascendant: ascendant,
            configuration: ascendant.backend,
            services: AscendantBackendServices(workspace: workspace, permission: permission),
            timelines: timelines,
            transport: transport
        )
        return Fixture(backend: backend, transport: transport, ascendantID: ascendantID, timelineID: timelineID)
    }

    private func workspaceReference(id: UUID, requiresPermission: Bool) -> BackendWorkspaceReference {
        BackendWorkspaceReference(
            id: id,
            uri: "echo://fixture",
            status: .available,
            tools: [BackendWorkspaceTool(
                id: "workspace_echo",
                name: "Workspace echo",
                description: "Echoes a value.",
                parametersSchema: .object(["type": .string("object")]),
                requiresPermission: requiresPermission
            )]
        )
    }

    @Test("an invalid envelope is rejected before publication")
    @MainActor
    func invalidConfigurationIsRejected() throws {
        let transport = FixtureLettaTransport()
        let ascendant = NodeManifest.Ascendant(
            id: UUID(), name: "Letta", defaultTimelineID: UUID(), backend: .init(kind: LettaAscendantBackend.kind)
        )

        #expect(throws: AscendantBackendError.self) {
            _ = try LettaAscendantBackend(
                ascendant: ascendant,
                configuration: ascendant.backend,
                services: .empty,
                timelines: [],
                transport: transport
            )
        }
    }

    @Test("the advertised settings schema names every Letta key")
    func settingsSchemaIsDeclared() {
        let schema = LettaAscendantBackend.settingsSchema
        #expect(schema.settingNames == ["serverURL", "model", "agentID", "agentName", "maxSteps"])
        #expect(schema.secretNames == ["apiKey"])
    }

    @Test("a Turn streams text, completes, and provisions one agent and conversation")
    @MainActor
    func plainTurn() async throws {
        let fixture = try makeFixture()
        let sink = UpdateRecorder()

        let text = try await fixture.backend.runTurn(
            AscendantBackendTurnRequest(timelineID: fixture.timelineID, message: "hello", clientTurnID: "turn-1"),
            updates: sink
        )

        #expect(text == "reply: hello")
        #expect(await sink.kinds == ["assistant_text", "completion"])
        #expect(await sink.terminal)
        #expect(await fixture.transport.agentCount == 1)
        #expect(await fixture.transport.conversationCount == 1)
        #expect(try await fixture.backend.operatedTimelines().count == 1)
    }

    @Test("Timeline creation is idempotent against remote conversation state")
    @MainActor
    func timelineCreationIsIdempotent() async throws {
        let fixture = try makeFixture()
        let createdID = UUID()

        let first = try await fixture.backend.createTimeline(id: createdID, title: "Created")
        let second = try await fixture.backend.createTimeline(id: createdID, title: "Created")
        #expect(first.id == createdID)
        #expect(second.id == createdID)
        #expect(await fixture.transport.conversationCount == 1)

        await fixture.backend.removeTimeline(id: createdID)
        let remaining = try await fixture.backend.operatedTimelines()
        #expect(remaining.map(\.id) == [fixture.timelineID])

        await fixture.backend.removeTimeline(id: UUID())
        #expect(await fixture.transport.conversationCount == 1)
    }

    @Test("a Workspace tool call is mediated, executed on the host, and returned")
    @MainActor
    func workspaceToolCallIsMediated() async throws {
        let workspaceID = UUID()
        let workspace = StubWorkspaceService(
            reference: workspaceReference(id: workspaceID, requiresPermission: true),
            result: BackendWorkspaceResult(message: "echoed")
        )
        let permission = StubPermissionService(decision: .approved)
        let fixture = try makeFixture(
            script: { _ in .clientTool(name: "workspace_echo", arguments: #"{"value":"hello"}"#, finalText: "tool done") },
            attachments: [workspaceID],
            workspace: workspace,
            permission: permission
        )

        let text = try await fixture.backend.runTurn(
            AscendantBackendTurnRequest(timelineID: fixture.timelineID, message: "use the tool", clientTurnID: "turn-2"),
            updates: UpdateRecorder()
        )

        #expect(text == "tool done")
        #expect(await fixture.backend.enabledToolIDs(for: fixture.timelineID) == ["workspace_echo"])
        #expect(workspace.invocations.map(\.toolID) == ["workspace_echo"])
        #expect(await permission.requestCount == 1)
        #expect(await fixture.transport.recordedClientTools.map(\.name) == ["workspace_echo"])
        #expect(await fixture.transport.recordedToolReturns == [
            LettaToolReturn(toolCallID: "call-1", content: "echoed", isError: false),
        ])
    }

    @Test("a denied permission never reaches the Workspace")
    @MainActor
    func deniedPermissionSkipsExecution() async throws {
        let workspaceID = UUID()
        let workspace = StubWorkspaceService(
            reference: workspaceReference(id: workspaceID, requiresPermission: true),
            result: BackendWorkspaceResult(message: "echoed")
        )
        let fixture = try makeFixture(
            script: { _ in .clientTool(name: "workspace_echo", arguments: "{}", finalText: "denied path") },
            attachments: [workspaceID],
            workspace: workspace,
            permission: StubPermissionService(decision: .denied)
        )

        _ = try await fixture.backend.runTurn(
            AscendantBackendTurnRequest(timelineID: fixture.timelineID, message: "use", clientTurnID: "turn-3"),
            updates: UpdateRecorder()
        )

        #expect(workspace.invocations.isEmpty)
        #expect(await fixture.transport.recordedToolReturns == [
            LettaToolReturn(toolCallID: "call-1", content: "Permission denied.", isError: true),
        ])
    }

    @Test("cancellation reaches the remote conversation and surfaces as cancelled")
    @MainActor
    func cancellationSurfaces() async throws {
        let fixture = try makeFixture(script: { _ in .hang })
        let sink = UpdateRecorder()

        let turn = Task {
            try await fixture.backend.runTurn(
                AscendantBackendTurnRequest(timelineID: fixture.timelineID, message: "hang", clientTurnID: "turn-4"),
                updates: sink
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        await fixture.backend.cancel()

        do {
            _ = try await turn.value
            Issue.record("The hung Letta Turn did not cancel.")
        } catch let error as AscendantBackendError {
            #expect(error == .cancelled)
        }
        #expect(await fixture.transport.cancelCount >= 1)
    }

    @Test("a server outage is lifecycle-unusable; a protocol failure is terminal")
    @MainActor
    func failureClassification() async throws {
        let unreachable = try makeFixture()
        await unreachable.transport.setSendFailure(.unreachable("offline"))
        await #expect(throws: AscendantBackendError.self) {
            _ = try await unreachable.backend.runTurn(
                AscendantBackendTurnRequest(timelineID: unreachable.timelineID, message: "x"),
                updates: UpdateRecorder()
            )
        }

        let protocolFailure = try makeFixture()
        await protocolFailure.transport.setSendFailure(.protocolFailure("bad response"))
        do {
            _ = try await protocolFailure.backend.runTurn(
                AscendantBackendTurnRequest(timelineID: protocolFailure.timelineID, message: "x"),
                updates: UpdateRecorder()
            )
            Issue.record("Expected a terminal protocol failure.")
        } catch let error as AscendantBackendError {
            guard case .terminal = error else {
                Issue.record("Expected terminal, got \(error).")
                return
            }
        }
    }

    @Test("an unknown Timeline is rejected rather than silently served")
    @MainActor
    func unknownTimelineIsRejected() async throws {
        let fixture = try makeFixture()
        await #expect(throws: AscendantBackendError.self) {
            _ = try await fixture.backend.runTurn(
                AscendantBackendTurnRequest(timelineID: UUID(), message: "x"),
                updates: UpdateRecorder()
            )
        }
    }

    @Test("the URLSession transport speaks the Letta HTTP and SSE wire format")
    func urlSessionTransportAgainstFixtureServer() async throws {
        let server: FixtureHTTPServerProcess
        do {
            server = try FixtureHTTPServerProcess()
        } catch {
            // The HTTP fixture needs node. The dev container provides it.
            return
        }
        defer { server.stop() }

        let transport = URLSessionLettaTransport(baseURL: server.baseURL, apiKey: "fixture")
        #expect(try await transport.health().isUsable)

        let agent = try await transport.createAgent(.init(name: "Fixture"))
        #expect(agent.id.hasPrefix("agent-"))

        let timelineID = UUID()
        let conversation = try await transport.createConversation(
            agentID: agent.id,
            description: "Default [gnostic:\(timelineID.uuidString.lowercased())]"
        )
        #expect(conversation.id.hasPrefix("conv-"))

        var events: [LettaStreamEvent] = []
        let stream = try await transport.sendMessage(
            agentID: agent.id,
            conversationID: conversation.id,
            input: .user("hi"),
            clientTools: []
        )
        for try await event in stream { events.append(event) }
        #expect(events.contains(.assistantText("http-reply")))
        #expect(events.contains(.stopReason("end_turn")))

        try await transport.cancelConversation(agentID: agent.id, conversationID: conversation.id)
    }
}
