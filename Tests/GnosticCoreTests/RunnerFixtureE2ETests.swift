// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared
import PositronicKit
import Testing

@Suite("Gnostic runner fixture")
struct RunnerFixtureE2ETests {
    @Test("runner fixture scenario completes through the broker") @MainActor
    func fixtureScenarioCompletes() async throws {
        let providerContainer = try container(named: "fixture-provider")
        let provider = try #require(providerContainer.communicationManager)
        let consumer = manager(named: "fixture-consumer")
        defer { providerContainer.shutdown(); consumer.stop() }
        try await providerContainer.startAndWaitUntilReady()
        try await start(consumer)
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }

        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let fixture = WorkspaceProvider(
            workspaceID: workspaceID,
            tools: [
                .init(id: "list_files", name: "List files", description: "Lists fixture files."),
                .init(id: "read_file", name: "Read file", description: "Reads a fixture file."),
                .init(
                    id: "workspace_echo",
                    name: "Workspace echo",
                    description: "Echoes fixture input.",
                    parametersSchema: workspaceEchoSchema
                ),
            ]
        ) { toolID, arguments in
            switch toolID {
            case "list_files": return .success("README.md")
            case "read_file": return .success("fixture contents")
            case "workspace_echo": return .success(arguments["value"]?.value as? String ?? "")
            default: return .failure("unknown fixture tool")
            }
        }
        let registration = try await fixture.register(on: provider)
        defer { registration.cancel() }
        let lifecycle = try #require(providerContainer.getController(name: "ObjectLifecycleController") as ObjectLifecycleController?)
        lifecycle.advertiseDiscoverableObject(object: GnosticWorkspaceObject(workspace: fixtureReference(id: workspaceID)))
        try await waitForWorkspace(catalog, id: workspaceID)
        let store = InMemoryWorkspacePersistence()
        let factory = AxolotyWorkspaceFactory(catalog: catalog) { invocation in
            let encoded = try JSONEncoder().encode(invocation)
            let response = try await consumer.call(operation: WorkspaceProvider.invocationOperation, parameters: String(decoding: encoded, as: UTF8.self), timeout: .seconds(3))
            return try JSONDecoder().decode(ToolResult.self, from: Data(response.result.utf8))
        }
        let manager = TimelineManager(
            stores: .init(timelineStore: InMemoryTimelinePersistence(), messageStore: InMemoryMessageStore(), workspaceStore: store, toolPersistence: InMemoryToolPersistence()),
            workspaceProfile: .noWorkspace,
            workspaceCreator: factory
        )
        let timeline = try await manager.createTimeline()
        let readvertised = TimelineRecorder()
        let attachment = DiscoveredWorkspaceAttachmentService(catalog: catalog, timelineManager: manager) { readvertised.record($0) }
        _ = try await attachment.attach(workspaceID: workspaceID, to: timeline.id, approved: true)

        let reference = try #require(try await manager.getWorkspaces(for: timeline.id).primary)
        let echoTool = try #require(reference.tools.first { $0.toolID == "workspace_echo" })
        guard case let .custom(echoDefinition) = echoTool else {
            Issue.record("workspace_echo must remain a custom tool after broker discovery")
            return
        }
        #expect(echoDefinition.parametersSchema == workspaceEchoSchema)
        let workspace = try factory.create(from: reference)
        #expect((try await workspace.executeTool(id: "list_files", parameters: [:])).output == "README.md")
        #expect((try await workspace.executeTool(id: "read_file", parameters: [:])).output == "fixture contents")
        #expect((try await workspace.executeTool(id: "workspace_echo", parameters: ["value": AnyCodable("network")])).output == "network")
        #expect(readvertised.timelines.last?.attachedWorkspaceIDs == [workspaceID])
    }

    @Test("a later turn uses a captured outcome without the full transcript")
    func laterTurnUsesCapturedOutcome() async throws {
        let store = InMemoryNarrativeStore()
        let capture = NarrativeCaptureService(
            store: store,
            proposer: CapturingProposer(),
            validator: NarrativeValidator(
                sensitiveValueMatch: { _ in false },
                existingEntries: { [] }
            ),
            sensitiveValueHandler: { _ in false }
        )
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!
        _ = await capture.capture(input: NarrativeCaptureInput(
            taskID: "e2e",
            outcome: .success,
            affectsLaterBehavior: true,
            openThread: nil,
            source: NarrativeSourceReference(
                conversation: NarrativeConversationRange(firstMessageID: "e-1", lastMessageID: "e-2"),
                toolIDs: ["list_files"],
                workspaceIDs: [workspaceID]
            )
        ))
        await capture.shutdown()

        let packet = await capture.relevantPacket(
            query: NarrativeRetrievalQuery(currentUserText: "outcome", limit: 5)
        )
        let text = try #require(packet?.text)
        #expect(text.contains("Reuse earlier outcomes in later turns."))
        #expect(!text.contains("full original transcript text"))
    }
}

/// A deterministic proposer that yields a reusable lesson without any LLM.
private struct CapturingProposer: NarrativeProposer {
    func propose(for input: NarrativeCaptureInput) async -> NarrativeProposal? {
        NarrativeProposal(
            id: NarrativeEntryID(),
            kind: .lesson,
            occurredAt: Date(),
            source: input.source,
            observation: "A bounded task completed.",
            interpretation: "Reusable outcome captured.",
            lesson: ProposedLesson(summary: "Reuse earlier outcomes in later turns."),
            importance: 0.6,
            confidence: 0.85,
            supportingEpisodes: [],
            isFactStatedSpeculation: false,
            isOverbroadSelfCharacterization: false
        )
    }
}

@MainActor
private func manager(named name: String) -> CommunicationManager {
    try! CommunicationManager(identity: Identity(name: name), communicationOptions: .init(namespace: "gnostic-runner-fixture-tests", shouldEnableCrossNamespacing: false, mqttClientOptions: .init(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false), shouldAutoStart: false), commonOptions: nil)
}

@MainActor
private func container(named name: String) throws -> Container {
    try Container.resolve(
        components: Components(controllers: ["ObjectLifecycleController": ObjectLifecycleController.self], objectTypes: [GnosticWorkspaceObject.self]),
        configuration: Configuration(
            common: CommonOptions(agentIdentity: ["name": name]),
            communication: CommunicationOptions(namespace: "gnostic-runner-fixture-tests", shouldEnableCrossNamespacing: false, mqttClientOptions: MQTTClientOptions(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false), shouldAutoStart: false)
        )
    )
}

@MainActor
private func start(_ manager: CommunicationManager) async throws {
    let stream = await manager.observeCommunicationStateStream()
    var iterator = stream.makeAsyncIterator()
    try manager.start()
    while let state = await iterator.next() {
        if state == .online { return }
    }
    throw CancellationError()
}

private final class TimelineRecorder: @unchecked Sendable {
    private(set) var timelines: [Timeline] = []
    func record(_ timeline: Timeline) { timelines.append(timeline) }
}

private func fixtureReference(id: UUID) -> WorkspaceReference {
    WorkspaceReference(
        id: id,
        uri: WorkspaceURI(parsing: "workspace://fixture")!,
        location: .runtime,
        tools: [
            .custom(.init(id: "list_files", name: "List files", description: "Lists fixture files.")),
            .custom(.init(id: "read_file", name: "Read file", description: "Reads a fixture file.")),
            .custom(.init(
                id: "workspace_echo",
                name: "Workspace echo",
                description: "Echoes fixture input.",
                parametersSchema: workspaceEchoSchema
            )),
        ]
    )
}

private let workspaceEchoSchema: [String: AnyCodable] = [
    "type": AnyCodable("object"),
    "properties": AnyCodable([
        "value": AnyCodable(["type": AnyCodable("string")]),
    ]),
    "required": AnyCodable(["value"]),
]

private func waitForWorkspace(_ catalog: NetworkCatalog, id: UUID) async throws {
    for _ in 0..<50 {
        if case .available = await catalog.workspaceAttachmentStatus(id: id) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw CancellationError()
}
