// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
@testable import GnosticPositronicBackend
@testable import GnosticCore
import GnosticWorkspaceTestSupport
import PKContracts
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
        defer { subscription.stopInTeardown() }

        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let fixture = makeWorkspaceInvocationProvider(
            workspaceID: workspaceID,
            tools: [
                .init(id: "list_files", name: "List files", description: "Lists fixture files."),
                .init(id: "read_file", name: "Read file", description: "Reads a fixture file."),
                .init(
                    id: "workspace_echo",
                    name: "Workspace echo",
                    description: "Echoes fixture input.",
                    parametersSchema: gnosticWorkspaceEchoSchema
                ),
            ]
        ) { toolID, arguments in
            switch toolID {
            case "list_files": return .success("README.md")
            case "read_file": return .success("fixture contents")
            case "workspace_echo":
                guard case let .string(value)? = arguments["value"] else { return .success("") }
                return .success(value)
            default: return .failure("unknown fixture tool")
            }
        }
        let registration = try await fixture.register(on: provider)
        defer { registration.cancel() }
        let lifecycle = try #require(providerContainer.controller(named: "ObjectLifecycleController") as ObjectLifecycleController?)
        lifecycle.advertiseDiscoverableObject(object: GnosticWorkspaceObject(
            workspace: fixtureReference(id: workspaceID)
        ))
        try await waitForWorkspace(catalog, id: workspaceID)
        let store = InMemoryWorkspacePersistence()
        let runtimeRepository = InMemoryTimelineRuntimeRepository()
        let factory = RemoteWorkspaceFactory(catalog: catalog) { invocation in
            let encoded = try JSONEncoder().encode(invocation)
            let response = try await consumer.call(operation: GnosticWorkspaceProtocol.invocationOperation, parameters: String(decoding: encoded, as: UTF8.self), timeout: .seconds(3))
            return try JSONDecoder().decode(ToolResult.self, from: Data(response.result.utf8))
        }
        let kit = PKRuntime(configuration: .init(
            languageModel: UnconfiguredLLMService(),
            persistence: .init(runtimeRepository: runtimeRepository, workspacePersistence: store, workspaceBindingRepository: runtimeRepository),
            runtime: .init(workspaceCreator: factory)
        ))
        let timeline = try await kit.timelines.create()
        // The production host commits the attachment. This fixture binds the
        // same host capability to the kit operations the bundled adapter
        // exposes, so the discovered Workspace is available to the factory.
        let attachmentHost = BackendWorkspaceAttachmentCapability { workspaceID, timelineID in
            guard case let .available(providerID, uri) = await catalog.workspaceAttachmentStatus(id: workspaceID),
                  let descriptor = await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID),
                  descriptor.uri == uri,
                  let reference = try? PositronicWorkspaceProjection.reference(from: descriptor) else {
                throw DiscoveredWorkspaceAttachmentError.invalidURI
            }
            try await kit.workspaces.update(reference)
            try await kit.timelines.attachWorkspace(reference.id, to: timelineID)
        }
        let attachment = DiscoveredWorkspaceAttachmentService(
            discovery: CatalogWorkspaceDiscovery(catalog: catalog),
            threadCapability: kit.timelines,
            hostAttachment: attachmentHost
        )
        _ = try await attachment.attach(workspaceID: workspaceID, to: timeline.id)

        guard let reference = try await kit.workspaces.get(workspaceID) else {
            Issue.record("attached workspace was not persisted")
            return
        }
        let echoTool = try #require(reference.tools.first { $0.toolID == "workspace_echo" })
        guard case let .custom(echoDefinition) = echoTool else {
            Issue.record("workspace_echo must remain a custom tool after broker discovery")
            return
        }
        #expect(echoDefinition.parametersSchema == workspaceEchoSchema)
        guard let workspace = try factory.create(from: reference) as? any WorkspaceToolProvider else {
            Issue.record("workspace factory returned a provider without tool support")
            return
        }
        #expect((try await workspace.executeTool(id: "list_files", parameters: [:])).output == "README.md")
        #expect((try await workspace.executeTool(id: "read_file", parameters: [:])).output == "fixture contents")
        #expect((try await workspace.executeTool(id: "workspace_echo", parameters: ["value": AnyCodable("network")])).output == "network")
        #expect(try await runtimeRepository.bindings(for: timeline.id).map(\.workspaceID) == [workspaceID])
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

private let gnosticWorkspaceEchoSchema: [String: ManifestJSONValue] = [
    "type": .string("object"),
    "properties": .object([
        "value": .object(["type": .string("string")]),
    ]),
    "required": .array([.string("value")]),
]

private func waitForWorkspace(_ catalog: NetworkCatalog, id: UUID) async throws {
    for _ in 0..<50 {
        if case .available = await catalog.workspaceAttachmentStatus(id: id) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw CancellationError()
}
