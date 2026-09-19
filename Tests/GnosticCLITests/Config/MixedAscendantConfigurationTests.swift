// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import JSONSchema
import PKContracts
import PositronicKit
import Testing

@testable import GnosticCLI

/// Proves that one Node hosts distinct Ascendant configurations side by side.
///
/// The scenario is three Ascendants on one `NodeRuntime`:
///
/// 1. a plain Positronic Ascendant with a scripted model;
/// 2. a Positronic Ascendant that selects a fixture extension contributing one
///    tool and one Turn context source; and
/// 3. an Ascendant served by a non-Positronic fixture backend kind.
///
/// Extension selection uses the production composition seam
/// (`BackendComposition.contributions`), so the test cannot pass with a
/// resolution path that production does not use.
@Suite("Mixed Ascendant configurations", .serialized)
struct MixedAscendantConfigurationTests {
    @Test("one Node hosts a plain, an extended, and a foreign-kind Ascendant side by side")
    @MainActor
    func hostsThreeConfigurations() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-hosts")
        defer { shutdown(node) }
        try await node.runtime.start()

        let snapshot = await node.runtime.snapshot()
        #expect(Set(snapshot.ascendantIDs) == [node.plainID, node.extendedID, node.fixtureID])

        let plain = try await node.runtime.turn(.init(
            message: "plain",
            timelineID: node.plainTimelineID,
            clientTurnID: "mixed-plain-1"
        ))
        let extended = try await node.runtime.turn(.init(
            message: "extended",
            timelineID: node.extendedTimelineID,
            clientTurnID: "mixed-extended-1"
        ))
        let fixture = try await node.runtime.turn(.init(
            message: "fixture",
            timelineID: node.fixtureTimelineID,
            clientTurnID: "mixed-fixture-1"
        ))

        #expect(plain.text == "plain-response")
        #expect(extended.text == "extended-response")
        #expect(fixture.text == "fixture: fixture")

        #expect(await node.runtime.backendHealth(for: node.plainID) == .healthy)
        #expect(await node.runtime.backendHealth(for: node.extendedID) == .healthy)
        #expect(await node.runtime.backendHealth(for: node.fixtureID) == .healthy)
    }

    @Test("a selected extension contributes only to the Ascendant that selected it")
    @MainActor
    func extensionContributionIsPerAscendant() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-isolation")
        defer { shutdown(node) }
        try await node.runtime.start()

        _ = try await node.runtime.turn(.init(
            message: "plain",
            timelineID: node.plainTimelineID,
            clientTurnID: "mixed-isolation-plain"
        ))
        _ = try await node.runtime.turn(.init(
            message: "extended",
            timelineID: node.extendedTimelineID,
            clientTurnID: "mixed-isolation-extended"
        ))

        // The contributed tool and context reach only the selecting Ascendant.
        #expect(try await node.runtime.enabledToolIDs(for: node.extendedTimelineID).contains("mixed_fixture_tool"))
        #expect(!(try await node.runtime.enabledToolIDs(for: node.plainTimelineID).contains("mixed_fixture_tool")))
        #expect(!(try await node.runtime.enabledToolIDs(for: node.fixtureTimelineID).contains("mixed_fixture_tool")))

        #expect(await node.extendedModel.capturedToolNames().contains("mixed_fixture_tool"))
        #expect(!(await node.plainModel.capturedToolNames().contains("mixed_fixture_tool")))
        #expect(await node.extendedModel.capturedPromptText().contains("mixed-context-marker"))
        #expect(!(await node.plainModel.capturedPromptText().contains("mixed-context-marker")))
        // The context source observes only the selecting Ascendant's Turn.
        #expect(await node.contributionProbe.contextAscendantIDs == [node.extendedID])
    }

    @Test("replay is answered per Ascendant without re-running the model")
    @MainActor
    func replayIsPerAscendant() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-replay")
        defer { shutdown(node) }
        try await node.runtime.start()

        let request = AscendantTurnRequest(
            message: "replay",
            timelineID: node.plainTimelineID,
            clientTurnID: "mixed-replay-plain"
        )
        let first = try await node.runtime.turn(request)
        #expect(!first.replayed)
        let invocations = await node.plainModel.invocationCount

        let replay = try await node.runtime.turn(request)
        #expect(replay.replayed)
        #expect(replay.text == "plain-response")
        #expect(await node.plainModel.invocationCount == invocations)

        let fixtureRequest = AscendantTurnRequest(
            message: "replay",
            timelineID: node.fixtureTimelineID,
            clientTurnID: "mixed-replay-fixture"
        )
        _ = try await node.runtime.turn(fixtureRequest)
        let fixtureReplay = try await node.runtime.turn(fixtureRequest)
        #expect(fixtureReplay.replayed)
        #expect(fixtureReplay.text == "fixture: replay")
    }

    @Test("a quarantined backend does not affect the other Ascendants")
    @MainActor
    func quarantinedBackendIsIsolated() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-quarantine")
        defer { shutdown(node) }
        try await node.runtime.start()

        // Prime the healthy Ascendants, then fail the fixture backend.
        #expect(try await node.runtime.turn(.init(
            message: "a", timelineID: node.plainTimelineID, clientTurnID: "mixed-quarantine-plain"
        )).text == "plain-response")
        #expect(try await node.runtime.turn(.init(
            message: "b", timelineID: node.extendedTimelineID, clientTurnID: "mixed-quarantine-extended"
        )).text == "extended-response")

        await node.fixtureProbe.setFailMode()
        do {
            _ = try await node.runtime.turn(.init(
                message: "fail", timelineID: node.fixtureTimelineID, clientTurnID: "mixed-quarantine-fixture"
            ))
            Issue.record("The lifecycle-unusable fixture backend did not fail the Turn.")
        } catch {
            // Expected: the failure is contained to the addressed Ascendant.
        }

        #expect(await node.runtime.backendHealth(for: node.fixtureID) == .failed)
        #expect(await node.runtime.backendHealth(for: node.plainID) == .healthy)
        #expect(await node.runtime.backendHealth(for: node.extendedID) == .healthy)

        #expect(try await node.runtime.turn(.init(
            message: "still", timelineID: node.plainTimelineID, clientTurnID: "mixed-quarantine-plain-2"
        )).text == "plain-response")
        #expect(try await node.runtime.turn(.init(
            message: "still", timelineID: node.extendedTimelineID, clientTurnID: "mixed-quarantine-extended-2"
        )).text == "extended-response")
    }

    @Test("remote selection reaches an Ascendant by id and rejects an absent id as ambiguous")
    @MainActor
    func remoteSelectionByAscendantID() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-selection")
        defer { shutdown(node) }
        try await node.runtime.start()

        let probe = try ACPBrokerProbe(
            host: "127.0.0.1",
            port: 1883,
            namespace: node.manifest.broker.namespace
        )
        defer { probe.stop() }
        try await probe.connect()
        let ascendants = try await waitForAscendantCount(3, using: probe)

        let expectedTimelines: [UUID: UUID] = [
            node.plainID: node.plainTimelineID,
            node.extendedID: node.extendedTimelineID,
            node.fixtureID: node.fixtureTimelineID,
        ]
        for ascendant in ascendants {
            let selected = try await probe.selectAscendant(id: ascendant.id)
            #expect(selected.id == ascendant.id)
            #expect(selected.timelineID == expectedTimelines[ascendant.id])
        }

        // Selection without an ID stays ambiguous on a multi-Ascendant Node.
        do {
            _ = try await probe.selectAscendant()
            Issue.record("Selection without an id resolved on a multi-Ascendant Node.")
        } catch let error as ACPBrokerProbe.Error {
            guard case .ambiguousAscendant = error else {
                Issue.record("Expected ambiguousAscendant, got \(error).")
                return
            }
        }

        // The remote transport resolves the same candidates and reports the
        // typed ambiguity error.
        let candidates = ascendants.map { ascendant in
            RemoteTurnClient.DiscoveredAscendant(
                id: ascendant.id,
                name: ascendant.name,
                timelineID: ascendant.timelineID,
                providerID: ascendant.providerID,
                capabilities: ascendant.capabilities
            )
        }
        #expect(try RemoteTurnClient.selectCandidate(from: candidates, id: node.extendedID).id == node.extendedID)
        do {
            _ = try RemoteTurnClient.selectCandidate(from: candidates)
            Issue.record("RemoteTurnClient selected without an id on a multi-Ascendant Node.")
        } catch let error as RemoteTurnClientError {
            #expect(error.gnosticCode == "ambiguousAscendant")
        }
    }

    @Test("Workspace attachment is projected per Ascendant")
    @MainActor
    func workspaceAttachmentIsPerAscendant() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-workspace")
        defer { shutdown(node) }
        try await node.runtime.start()

        #expect(try await node.runtime.attachWorkspace(.init(
            workspaceID: node.workspaceID, timelineID: node.plainTimelineID
        )))
        #expect(try await node.runtime.attachWorkspace(.init(
            workspaceID: node.workspaceID, timelineID: node.extendedTimelineID
        )))

        let plainTimeline = try #require(await node.runtime.timeline(id: node.plainTimelineID))
        #expect(plainTimeline.attachedWorkspaceIDs == [node.workspaceID])
        #expect(try await node.runtime.enabledToolIDs(for: node.plainTimelineID).contains(EchoWorkspace.toolID))
        #expect(try await node.runtime.enabledToolIDs(for: node.extendedTimelineID).contains(EchoWorkspace.toolID))

        let result = try await node.runtime.executeWorkspaceTool(
            workspaceID: node.workspaceID,
            toolID: EchoWorkspace.toolID,
            arguments: ["value": AnyCodable("mixed")]
        )
        #expect(result.output == "mixed")

        // The non-Positronic backend consumes no Workspaces, so attaching to its
        // Timeline fails without disturbing the others.
        await #expect(throws: NodeRuntimeError.self) {
            _ = try await node.runtime.attachWorkspace(.init(
                workspaceID: node.workspaceID, timelineID: node.fixtureTimelineID
            ))
        }
        #expect(try await node.runtime.enabledToolIDs(for: node.plainTimelineID).contains(EchoWorkspace.toolID))
    }

    @Test("shutdown cancels and retires every Ascendant, including a hung fixture Turn")
    @MainActor
    func shutdownCancelsEveryAscendant() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-shutdown")
        try await node.runtime.start()

        #expect(try await node.runtime.turn(.init(
            message: "a", timelineID: node.plainTimelineID, clientTurnID: "mixed-shutdown-plain"
        )).text == "plain-response")

        await node.fixtureProbe.setHangMode()
        let hung = Task {
            try await node.runtime.turn(.init(
                message: "hang", timelineID: node.fixtureTimelineID, clientTurnID: "mixed-shutdown-fixture"
            ))
        }
        await node.fixtureProbe.waitUntilHanging()

        await node.runtime.shutdown()

        #expect(await node.fixtureProbe.cancelCount >= 1)
        #expect(await node.fixtureProbe.shutdownCount >= 1)
        switch await hung.result {
        case .success:
            Issue.record("The hung fixture Turn unexpectedly succeeded after shutdown.")
        case .failure:
            break
        }
    }

    @Test("the same scenario without extensions matches the unchanged behavior")
    @MainActor
    func withoutExtensionsIsUnchanged() async throws {
        let node = try await makeMixedNode(namespace: "mixed-ascendant-no-extensions", includeExtension: false)
        defer { shutdown(node) }
        try await node.runtime.start()

        let request = AscendantTurnRequest(
            message: "no extension",
            timelineID: node.extendedTimelineID,
            clientTurnID: "mixed-no-extension"
        )
        let first = try await node.runtime.turn(request)
        #expect(first.text == "extended-response")
        #expect(!first.replayed)

        let replay = try await node.runtime.turn(request)
        #expect(replay.replayed)
        #expect(replay.text == "extended-response")

        #expect(!(try await node.runtime.enabledToolIDs(for: node.extendedTimelineID).contains("mixed_fixture_tool")))
        #expect(!(await node.extendedModel.capturedPromptText().contains("## Turn Context")))
        #expect(await node.contributionProbe.contextAscendantIDs.isEmpty)
    }

    @Test("permission mediation for a contributed tool is scoped to its Ascendant")
    @MainActor
    func permissionMediationIsPerAscendant() async throws {
        let ascendantID = UUID()
        let timelineID = UUID()
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let model = MixedScriptedModel(
            response: "approved-result",
            toolCallName: "mixed_fixture_tool",
            toolCallArguments: #"{"value":"x"}"#
        )
        let adapter = try await PositronicAscendantAdapter(
            ascendant: .init(id: ascendantID, name: "Permission", defaultTimelineID: timelineID),
            backend: .init(kind: "positronic"),
            services: .init(permission: coordinator),
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)],
            languageModel: model,
            contributions: [MixedFixtureContribution(
                label: "fixture",
                tools: [MixedFixtureTool(callName: "mixed_fixture_tool", requiresPermission: true).toAnyTool()]
            )]
        )

        let turn = Task {
            try await adapter.runTurn(
                AscendantBackendTurnRequest(timelineID: timelineID, message: "run the tool", clientTurnID: "mixed-permission-turn"),
                updates: MixedNoopUpdateSink()
            )
        }
        let correlationID = try await waitForPermissionCorrelation(
            updates: updates,
            timelineID: timelineID,
            clientTurnID: "mixed-permission-turn"
        )
        _ = await coordinator.respond(
            correlationID: correlationID,
            timelineID: timelineID,
            clientTurnID: "mixed-permission-turn",
            approved: true
        )

        #expect(try await turn.value == "approved-result")
        #expect(await coordinator.pendingCount == 0)
    }

    // MARK: - Fixture construction

    private func makeMixedNode(
        namespace: String,
        includeExtension: Bool = true
    ) async throws -> MixedNode {
        let plainID = UUID()
        let extendedID = UUID()
        let fixtureID = UUID()
        let plainTimelineID = UUID()
        let extendedTimelineID = UUID()
        let fixtureTimelineID = UUID()
        let workspaceID = UUID()

        let plainModel = MixedScriptedModel(response: "plain-response")
        let extendedModel = MixedScriptedModel(response: "extended-response")
        let fixtureProbe = MixedFixtureProbe()
        let contributionProbe = MixedContributionProbe()

        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID()),
            ascendants: [
                .init(id: plainID, name: "Plain", defaultTimelineID: plainTimelineID),
                .init(
                    id: extendedID,
                    name: "Extended",
                    defaultTimelineID: extendedTimelineID,
                    backend: includeExtension
                        ? .init(kind: "positronic", settings: ["extensions": .array([.string("fixture")])])
                        : .init(kind: "positronic")
                ),
                .init(id: fixtureID, name: "Fixture", defaultTimelineID: fixtureTimelineID, kind: "fixture-scripted"),
            ],
            timelines: [
                .init(id: plainTimelineID, title: "Plain", operatingAscendantID: plainID),
                .init(id: extendedTimelineID, title: "Extended", operatingAscendantID: extendedID),
                .init(id: fixtureTimelineID, title: "Fixture", operatingAscendantID: fixtureID),
            ],
            workspaces: [.init(id: workspaceID, name: "Echo", uri: "echo://mixed")]
        )

        let extensions: [String: PositronicExtension] = includeExtension
            ? ["fixture": mixedFixtureExtension(probe: contributionProbe)]
            : [:]
        let models: [UUID: MixedScriptedModel] = [plainID: plainModel, extendedID: extendedModel]

        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: AscendantAdapterRegistry.positronicKind,
            settings: PositronicAscendantAdapter.settingsSchema
        ) { ascendant, backend, services, timelines in
            let contributions = try BackendComposition.contributions(
                for: ascendant,
                backend: backend,
                extensions: extensions
            )
            let model: any LLMStreamClient = models[ascendant.id] ?? UnconfiguredLLMService()
            return try await PositronicAscendantAdapter(
                ascendant: ascendant,
                backend: backend,
                services: services,
                timelines: timelines,
                languageModel: model,
                contributions: contributions
            )
        }
        adapters.ascendants.registerBackend(kind: "fixture-scripted") { ascendant, _, _, timelines in
            MixedFixtureBackend(ascendant: ascendant, timelines: timelines, probe: fixtureProbe)
        }

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        return MixedNode(
            runtime: runtime,
            manifest: manifest,
            plainID: plainID,
            extendedID: extendedID,
            fixtureID: fixtureID,
            plainTimelineID: plainTimelineID,
            extendedTimelineID: extendedTimelineID,
            fixtureTimelineID: fixtureTimelineID,
            workspaceID: workspaceID,
            plainModel: plainModel,
            extendedModel: extendedModel,
            fixtureProbe: fixtureProbe,
            contributionProbe: contributionProbe
        )
    }

    private func mixedFixtureExtension(probe: MixedContributionProbe) -> PositronicExtension {
        PositronicExtension(name: "fixture") { _ in
            MixedFixtureContribution(
                label: "fixture",
                tools: [MixedFixtureTool(callName: "mixed_fixture_tool").toAnyTool()],
                source: MixedContextSource(text: "mixed-context-marker", probe: probe)
            )
        }
    }

    private func shutdown(_ node: MixedNode) {
        Task { @MainActor in await node.runtime.shutdown() }
    }

    private func waitForAscendantCount(
        _ expected: Int,
        using probe: ACPBrokerProbe,
        timeout: Duration = .seconds(8)
    ) async throws -> [ACPBrokerProbe.DiscoveredAscendant] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var latest: [ACPBrokerProbe.DiscoveredAscendant] = []
        while clock.now < deadline {
            latest = await probe.discoverAscendants()
            if latest.count == expected { return latest }
            try await Task.sleep(for: .milliseconds(100))
        }
        return latest
    }

    private func waitForPermissionCorrelation(
        updates: AscendantTurnUpdateStore,
        timelineID: UUID,
        clientTurnID: String,
        timeout: Duration = .seconds(8)
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let replay = try await updates.replay(timelineID: timelineID, clientTurnID: clientTurnID)
            if let pending = replay.updates.compactMap(\.permissionState)
                .first(where: { $0.status == AscendantPermissionStatus.pending.rawValue }) {
                return pending.correlationID
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MixedTestError.permissionNeverRequested
    }
}

// MARK: - Fixture state

private struct MixedNode {
    let runtime: NodeRuntime
    let manifest: NodeManifest
    let plainID: UUID
    let extendedID: UUID
    let fixtureID: UUID
    let plainTimelineID: UUID
    let extendedTimelineID: UUID
    let fixtureTimelineID: UUID
    let workspaceID: UUID
    let plainModel: MixedScriptedModel
    let extendedModel: MixedScriptedModel
    let fixtureProbe: MixedFixtureProbe
    let contributionProbe: MixedContributionProbe
}

private enum MixedTestError: Error {
    case permissionNeverRequested
}

// MARK: - Contributions

private struct MixedFixtureContribution: PositronicContribution {
    let label: String
    private let toolList: [AnyTool]
    private let source: (any TurnContextSource)?

    init(label: String, tools: [AnyTool] = [], source: (any TurnContextSource)? = nil) {
        self.label = label
        toolList = tools
        self.source = source
    }

    func tools() -> [AnyTool] { toolList }
    func turnContextSource() -> (any TurnContextSource)? { source }
}

private struct MixedContextSource: TurnContextSource {
    let text: String
    let probe: MixedContributionProbe

    var failureRequirement: TurnContextContributionRequirement { .required }

    func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        await probe.recordContext(ascendantID: PositronicTurnInvocationContext.current?.ascendantID)
        return [try TurnContextContribution(namespace: "mixed", key: "note", text: text)]
    }
}

private struct MixedFixtureTool: Tool, Sendable {
    let callName: String
    let requiresPermission: Bool

    init(callName: String, requiresPermission: Bool = false) {
        self.callName = callName
        self.requiresPermission = requiresPermission
    }

    var identity: ToolReference { .known(id: callName) }
    var name: String { callName }
    var description: String { "Mixed-configuration fixture tool \(callName)." }
    var sideEffects: ToolSideEffects { .none }
    var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }
    func canExecute() async -> Bool { true }
    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult { .success("fixture-tool-result") }
}

private actor MixedContributionProbe {
    private(set) var contextAscendantIDs: [UUID] = []

    func recordContext(ascendantID: UUID?) {
        guard let ascendantID else { return }
        contextAscendantIDs.append(ascendantID)
    }
}

// MARK: - Non-Positronic fixture backend

private final class MixedFixtureBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    private var storedTimelines: [AscendantBackendTimeline]
    private let probe: MixedFixtureProbe

    init(ascendant: NodeManifest.Ascendant, timelines: [NodeManifest.Timeline], probe: MixedFixtureProbe) {
        let now = Date()
        self.probe = probe
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: .init(
                interoperability: [AscendantInteroperabilityCapability.textTurn.rawValue],
                backendKind: "fixture-scripted"
            )
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
            id: id,
            title: title,
            attachedWorkspaceIDs: [],
            ascendantID: identity.id,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
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
            id: current.id,
            title: title,
            attachedWorkspaceIDs: current.attachedWorkspaceIDs,
            ascendantID: current.ascendantID,
            isArchived: current.isArchived,
            isPrivate: current.isPrivate,
            createdAt: current.createdAt,
            updatedAt: Date()
        )
        storedTimelines[index] = renamed
        return renamed
    }

    func runTurn(_ request: AscendantBackendTurnRequest, updates: any AscendantBackendUpdateSink) async throws -> String {
        guard storedTimelines.contains(where: { $0.id == request.timelineID }) else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        await probe.recordTurn()
        if await probe.failMode {
            throw AscendantBackendError.lifecycleUnusable(
                .init(message: "The non-Positronic fixture backend is unusable.")
            )
        }
        if await probe.hangMode {
            await probe.markHanging()
            await probe.waitForCancellation()
            throw AscendantBackendError.cancelled
        }
        let reply = "fixture: \(request.message)"
        try await updates.append(.init(kind: AscendantTurnUpdateKind.assistantText.rawValue, text: reply))
        try await updates.append(.init(kind: AscendantTurnUpdateKind.completion.rawValue, text: reply, terminal: true))
        return reply
    }

    func cancel() async { await probe.recordCancel() }
    func shutdown() async { await probe.recordShutdown() }
}

private actor MixedFixtureProbe {
    private(set) var turnCount = 0
    private(set) var cancelCount = 0
    private(set) var shutdownCount = 0
    private(set) var failMode = false
    private(set) var hangMode = false
    private var hanging = false
    private var hangingWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func recordTurn() { turnCount += 1 }

    func recordCancel() {
        cancelCount += 1
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }

    func recordShutdown() { shutdownCount += 1 }

    func setFailMode() { failMode = true }

    func setHangMode() { hangMode = true }

    func markHanging() {
        hanging = true
        hangingWaiters.forEach { $0.resume() }
        hangingWaiters.removeAll()
    }

    func waitUntilHanging() async {
        guard !hanging else { return }
        await withCheckedContinuation { hangingWaiters.append($0) }
    }

    func waitForCancellation() async {
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}

// MARK: - Scripted model

private final class MixedScriptedModel: LLMStreamClient, @unchecked Sendable {
    private let response: String
    private let toolCallName: String?
    private let toolCallArguments: String
    private let capture = MixedModelCapture()

    init(response: String, toolCallName: String? = nil, toolCallArguments: String = "{}") {
        self.response = response
        self.toolCallName = toolCallName
        self.toolCallArguments = toolCallArguments
    }

    var invocationCount: Int {
        get async { await capture.invocationCount }
    }

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func capturedToolNames() async -> Set<String> { await capture.toolNames }

    func capturedPromptText() async -> String { await capture.promptText }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await capture.record(messages: messages, tools: tools ?? [])
        if let toolCallName, messages.last?.role != .tool {
            let chunk = LLMStreamChunk(
                id: "mixed-tool",
                model: "mixed",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(
                        role: .assistant,
                        toolCalls: [LLMToolCallDelta(
                            index: 0,
                            id: "call_1",
                            function: LLMToolCallDeltaFunction(
                                name: toolCallName,
                                arguments: toolCallArguments
                            )
                        )]
                    ),
                    finishReason: "tool_calls"
                )]
            )
            return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
        }
        let response = response
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMStreamChunk(
                id: "mixed",
                model: "mixed",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: response),
                    finishReason: "stop"
                )]
            ))
            continuation.finish()
        }
    }

    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await generationStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }

    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}
    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { response }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { response }
    func fetchAvailableModels() async throws -> [String]? { nil }

    private actor MixedModelCapture {
        private(set) var invocationCount = 0
        private(set) var promptText = ""
        private(set) var toolNames: Set<String> = []

        func record(messages: [LLMMessage], tools: [LLMToolDefinition]) {
            invocationCount += 1
            promptText = messages.map(\.content).joined(separator: "\n")
            toolNames = Set(tools.map(\.name))
        }
    }
}

private struct MixedNoopUpdateSink: AscendantBackendUpdateSink {
    func append(_: AscendantBackendUpdate) async throws {}
}
