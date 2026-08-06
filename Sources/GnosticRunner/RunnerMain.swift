// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Axoloty
import GnosticCore
import PKShared
import PositronicKit

@main
struct GnosticRunner {
    static func main() async {
        let configuration = RunnerConfiguration(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
        do {
            if configuration.scenario {
                try await FixtureScenario(configuration: configuration).run()
            } else {
                let runtime = try RunnerRuntime(configuration: configuration)
                defer { runtime.shutdown() }
                try await runtime.start()
                print("gnostic-runner online at \(configuration.host):\(configuration.port) namespace \(configuration.namespace)")
                await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                    _ = continuation
                }
            }
        } catch {
            print("gnostic-runner failed: \(error)")
            exit(1)
        }
    }
}

struct RunnerConfiguration: Sendable {
    let host: String
    let port: Int
    let namespace: String
    let scenario: Bool

    init(environment: [String: String], arguments: [String]) {
        host = Self.value(named: "host", environment: environment, arguments: arguments) ?? "127.0.0.1"
        port = Int(Self.value(named: "port", environment: environment, arguments: arguments) ?? "1883") ?? 1883
        namespace = Self.value(named: "namespace", environment: environment, arguments: arguments) ?? "gnostic"
        scenario = arguments.contains("--scenario")
    }

    private static func value(named name: String, environment: [String: String], arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "--\(name)"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        return environment["GNOSTIC_\(name.uppercased())"]
    }
}

@MainActor
private final class RunnerRuntime {
    let container: Container
    let communication: CommunicationManager
    let lifecycle: ObjectLifecycleController

    init(configuration: RunnerConfiguration) throws {
        container = try Container.resolve(
            components: Components(controllers: ["ObjectLifecycleController": ObjectLifecycleController.self], objectTypes: [GnosticAgentObject.self, GnosticTimelineObject.self, GnosticWorkspaceObject.self]),
            configuration: Configuration(
                common: CommonOptions(agentIdentity: ["name": "gnostic-runner"]),
                communication: CommunicationOptions(namespace: configuration.namespace, shouldEnableCrossNamespacing: false, mqttClientOptions: MQTTClientOptions(host: configuration.host, port: UInt16(configuration.port), shouldTryMDNSDiscovery: false, autoReconnect: false), shouldAutoStart: false)
            )
        )
        communication = try container.communicationManager.unwrap()
        lifecycle = try container.getController(name: "ObjectLifecycleController").unwrap()
    }

    func start() async throws { try await container.startAndWaitUntilReady() }
    func shutdown() { container.shutdown() }
}

@MainActor
private struct FixtureScenario {
    let configuration: RunnerConfiguration

    func run() async throws {
        let provider = try RunnerRuntime(configuration: configuration)
        let consumer = try RunnerRuntime(configuration: configuration)
        defer { provider.shutdown(); consumer.shutdown() }
        try await provider.start()
        try await consumer.start()

        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let tools = fixtureTools
        let workspace = WorkspaceReference(id: workspaceID, uri: WorkspaceURI(parsing: "workspace://fixture")!, location: .runtime, tools: tools.map(ToolReference.custom))
        let providerAPI = WorkspaceProvider(workspaceID: workspaceID, tools: tools) { toolID, arguments in
            switch toolID {
            case "list_files": return .success("README.md")
            case "read_file": return .success("fixture contents")
            case "workspace_echo": return .success(arguments["value"]?.value as? String ?? "")
            default: return .failure("unknown fixture tool")
            }
        }
        let registration = try await providerAPI.register(on: provider.communication)
        defer { registration.cancel() }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer.communication)
        try await subscription.start()
        defer { subscription.stop() }
        provider.lifecycle.advertiseDiscoverableObject(object: GnosticWorkspaceObject(workspace: workspace))
        try await waitForWorkspace(catalog, id: workspaceID)
        print("fixture workspace discovered: \(workspaceID.uuidString.lowercased())")

        let store = InMemoryWorkspacePersistence()
        let factory = AxolotyWorkspaceFactory(catalog: catalog) { invocation in
            let encoded = try JSONEncoder().encode(invocation)
            let response = try await consumer.communication.call(
                operation: WorkspaceProvider.invocationOperation,
                parameters: String(decoding: encoded, as: UTF8.self),
                timeout: .seconds(3)
            )
            return try JSONDecoder().decode(ToolResult.self, from: Data(response.result.utf8))
        }
        let manager = TimelineManager(
            stores: .init(timelineStore: InMemoryTimelinePersistence(), messageStore: InMemoryMessageStore(), workspaceStore: store, toolPersistence: InMemoryToolPersistence()),
            workspaceProfile: .noWorkspace,
            workspaceCreator: factory
        )
        let timeline = try await manager.createTimeline()
        let readvertised = TimelineReadvertisement()
        let attachment = DiscoveredWorkspaceAttachmentService(catalog: catalog, workspaceStore: store, timelineManager: manager) { readvertised.record($0) }
        let reference = try await attachment.attach(workspaceID: workspaceID, to: timeline.id, approved: true)
        let remote = AxolotyWorkspace(reference: reference, catalog: catalog, communication: consumer.communication, timeout: .seconds(3))
        try await invoke(remote, id: "list_files", arguments: [:], expected: "README.md")
        try await invoke(remote, id: "read_file", arguments: [:], expected: "fixture contents")
        try await invoke(remote, id: "workspace_echo", arguments: ["value": AnyCodable("network")], expected: "network")
        guard readvertised.latest?.attachedWorkspaceIDs == [workspaceID] else { throw RunnerError.timelineNotReadvertised }
        print("timeline readvertised with fixture workspace: \(workspaceID.uuidString.lowercased())")

        let narrative = NarrativeRuntime()
        let source = NarrativeSourceReference(
            conversation: NarrativeConversationRange(firstMessageID: "f-1", lastMessageID: "f-3"),
            toolIDs: ["list_files", "read_file", "workspace_echo"],
            workspaceIDs: [workspaceID]
        )
        _ = await narrative.capture.capture(input: NarrativeCaptureInput(
            taskID: "fixture",
            outcome: .success,
            affectsLaterBehavior: true,
            openThread: nil,
            source: source
        ))
        await narrative.shutdown()
        print("fixture scenario passed: list_files, read_file, workspace_echo used me.atkn.gnostic.workspace.invoke")
    }
}

private let fixtureTools = [
    WorkspaceToolDefinition(id: "list_files", name: "List files", description: "Lists fixture files."),
    WorkspaceToolDefinition(id: "read_file", name: "Read file", description: "Reads a fixture file."),
    WorkspaceToolDefinition(id: "workspace_echo", name: "Workspace echo", description: "Echoes fixture input."),
]

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw RunnerError.missingRuntimeComponent }
        return self
    }
}

private enum RunnerError: Error {
    case missingRuntimeComponent
    case timelineNotReadvertised
}

private final class TimelineReadvertisement: @unchecked Sendable {
    private(set) var latest: Timeline?
    func record(_ timeline: Timeline) { latest = timeline }
}

private func waitForWorkspace(_ catalog: NetworkCatalog, id: UUID) async throws {
    for _ in 0..<50 {
        if case .available = await catalog.workspaceAttachmentStatus(id: id) { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw CancellationError()
}

private func invoke(_ workspace: AxolotyWorkspace, id: String, arguments: [String: AnyCodable], expected: String) async throws {
    let result = try await workspace.executeTool(id: id, parameters: arguments)
    guard result.success, result.output == expected else { throw RunnerError.timelineNotReadvertised }
    print("generic network call passed: \(id)")
}
