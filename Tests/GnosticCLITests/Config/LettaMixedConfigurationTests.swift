// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticLettaBackend
import GnosticLettaTestSupport
import Testing

/// Proves a Letta Ascendant coexists with a non-Positronic fixture Ascendant on
/// one Node, and that a Letta Turn executes an attached Workspace tool on the
/// host, cancels, and retires on shutdown.
///
/// The Letta backend is registered through the same composition seam production
/// uses, with a fixture transport standing in for a live server. No Letta
/// credential or network is involved.
@Suite("Letta mixed Ascendant configuration", .serialized)
struct LettaMixedConfigurationTests {
    @Test("a Letta Ascendant runs a Turn and a host Workspace tool beside a fixture Ascendant")
    @MainActor
    func mixedNodeRunsWorkspaceTool() async throws {
        let node = try await makeNode(namespace: "letta-mixed-tools") { message in
            message == "use"
                ? .clientTool(name: "workspace_echo", arguments: #"{"value":"echoed"}"#, finalText: "letta-tool-done")
                : .plain("letta-response")
        }
        defer { shutdown(node) }
        try await node.runtime.start()

        let fixtureTurn = try await node.runtime.turn(.init(
            message: "hello", timelineID: node.fixtureTimelineID, clientTurnID: "letta-mixed-fixture"
        ))
        #expect(fixtureTurn.text == "fixture: hello")

        #expect(try await node.runtime.attachWorkspace(.init(
            workspaceID: node.workspaceID, timelineID: node.lettaTimelineID
        )))
        #expect(try await node.runtime.enabledToolIDs(for: node.lettaTimelineID).contains("workspace_echo"))

        let lettaTurn = try await node.runtime.turn(.init(
            message: "use", timelineID: node.lettaTimelineID, clientTurnID: "letta-mixed-use"
        ))
        #expect(lettaTurn.text == "letta-tool-done")
        #expect(await node.transport.recordedToolReturns == [
            LettaToolReturn(toolCallID: "call-1", content: "echoed", isError: false),
        ])

        #expect(await node.runtime.backendHealth(for: node.lettaID) == .healthy)
        #expect(await node.runtime.backendHealth(for: node.fixtureID) == .healthy)
    }

    @Test("shutdown cancels a hung Letta Turn without disturbing the fixture Ascendant")
    @MainActor
    func shutdownCancelsHungLettaTurn() async throws {
        let node = try await makeNode(namespace: "letta-mixed-shutdown") { _ in .hang }
        try await node.runtime.start()

        #expect(try await node.runtime.turn(.init(
            message: "a", timelineID: node.fixtureTimelineID, clientTurnID: "letta-shutdown-fixture"
        )).text == "fixture: a")

        let hung = Task {
            try await node.runtime.turn(.init(
                message: "hang", timelineID: node.lettaTimelineID, clientTurnID: "letta-shutdown-hang"
            ))
        }
        let deadline = ContinuousClock().now + .seconds(8)
        while (await node.transport.hangCount) == 0 && ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await node.transport.hangCount >= 1)

        await node.runtime.shutdown()

        #expect(await node.transport.cancelCount >= 1)
        switch await hung.result {
        case .success:
            Issue.record("The hung Letta Turn unexpectedly succeeded after shutdown.")
        case .failure:
            break
        }
    }

    private func makeNode(
        namespace: String,
        script: @escaping @Sendable (String) -> LettaFixtureScript
    ) async throws -> MixedLettaNode {
        let lettaID = UUID()
        let fixtureID = UUID()
        let lettaTimelineID = UUID()
        let fixtureTimelineID = UUID()
        let workspaceID = UUID()
        let transport = FixtureLettaTransport(scriptForMessage: script)

        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID()),
            ascendants: [
                .init(
                    id: lettaID,
                    name: "Letta",
                    defaultTimelineID: lettaTimelineID,
                    backend: .init(
                        kind: "letta",
                        settings: [
                            "serverURL": .string("http://127.0.0.1:8283"),
                            "model": .string("openai/test-model"),
                        ],
                        secrets: ["apiKey": .string("fixture-key")]
                    )
                ),
                .init(id: fixtureID, name: "Fixture", defaultTimelineID: fixtureTimelineID, kind: "fixture-scripted"),
            ],
            timelines: [
                .init(id: lettaTimelineID, title: "Letta", operatingAscendantID: lettaID),
                .init(id: fixtureTimelineID, title: "Fixture", operatingAscendantID: fixtureID),
            ],
            workspaces: [.init(id: workspaceID, name: "Echo", uri: "echo://letta-mixed")]
        )

        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: "letta",
            settings: LettaAscendantBackend.settingsSchema
        ) { ascendant, backend, services, timelines in
            try LettaAscendantBackend(
                ascendant: ascendant,
                configuration: backend,
                services: services,
                timelines: timelines,
                transport: transport
            )
        }
        adapters.ascendants.registerBackend(kind: "fixture-scripted") { ascendant, _, _, timelines in
            FixtureAscendantBackend(ascendant: ascendant, timelines: timelines)
        }

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        return MixedLettaNode(
            runtime: runtime,
            lettaID: lettaID,
            fixtureID: fixtureID,
            lettaTimelineID: lettaTimelineID,
            fixtureTimelineID: fixtureTimelineID,
            workspaceID: workspaceID,
            transport: transport
        )
    }

    private func shutdown(_ node: MixedLettaNode) {
        Task { @MainActor in await node.runtime.shutdown() }
    }
}

private struct MixedLettaNode {
    let runtime: NodeRuntime
    let lettaID: UUID
    let fixtureID: UUID
    let lettaTimelineID: UUID
    let fixtureTimelineID: UUID
    let workspaceID: UUID
    let transport: FixtureLettaTransport
}

/// A minimal non-Positronic backend so the Node hosts mixed kinds.
@MainActor
private final class FixtureAscendantBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    private var storedTimelines: [AscendantBackendTimeline]

    init(ascendant: NodeManifest.Ascendant, timelines: [NodeManifest.Timeline]) {
        let now = Date()
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: .init(interoperability: [AscendantInteroperabilityCapability.textTurn.rawValue], backendKind: "fixture-scripted")
        )
        storedTimelines = timelines.map {
            .init(
                id: $0.id,
                title: $0.title,
                attachedWorkspaceIDs: $0.attachments.map(\.workspaceID),
                ascendantID: ascendant.id,
                isArchived: false,
                isPrivate: false,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    func validateConfiguration() throws {}

    func operatedTimelines() async throws -> [AscendantBackendTimeline] { storedTimelines }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        let timeline = AscendantBackendTimeline(
            id: id, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id,
            isArchived: false, isPrivate: false, createdAt: now, updatedAt: now
        )
        storedTimelines.append(timeline)
        return timeline
    }

    func removeTimeline(id: UUID) async { storedTimelines.removeAll { $0.id == id } }

    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let index = storedTimelines.firstIndex(where: { $0.id == id }) else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        let current = storedTimelines[index]
        let renamed = AscendantBackendTimeline(
            id: current.id, title: title, attachedWorkspaceIDs: current.attachedWorkspaceIDs,
            ascendantID: current.ascendantID, isArchived: current.isArchived,
            isPrivate: current.isPrivate, createdAt: current.createdAt, updatedAt: Date()
        )
        storedTimelines[index] = renamed
        return renamed
    }

    func runTurn(_ request: AscendantBackendTurnRequest, updates: any AscendantBackendUpdateSink) async throws -> String {
        guard storedTimelines.contains(where: { $0.id == request.timelineID }) else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        let reply = "fixture: \(request.message)"
        try await updates.append(.init(kind: AscendantTurnUpdateKind.assistantText.rawValue, text: reply))
        try await updates.append(.init(kind: AscendantTurnUpdateKind.completion.rawValue, text: reply, terminal: true))
        return reply
    }

    func cancel() async {}
    func shutdown() async {}
}
