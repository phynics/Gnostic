// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import Axoloty
import GnosticCore
import PKShared
import PositronicKit

/// The `gnostic-runner` executable.
@main
struct GnosticRunner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic-runner",
        abstract: "Advertise Gnostic objects and drive the agent-network PoC."
    )

    @Option(help: "MQTT broker host (defaults to GNOSTIC_HOST or 127.0.0.1).")
    var host: String?

    @Option(help: "MQTT broker port (defaults to GNOSTIC_PORT or 1883).")
    var port: Int?

    @Option(help: "MQTT namespace (defaults to GNOSTIC_NAMESPACE or gnostic).")
    var namespace: String?

    @Flag(help: "Run the deterministic fixture scenario instead of the online runner.")
    var scenario = false

    @MainActor
    func run() async throws {
        let configuration = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: host, port: port, namespace: namespace),
            environment: ProcessInfo.processInfo.environment
        )
        if scenario {
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
    }
}

/// Structured parsing failures for the runner's command-line configuration.
public enum RunnerParsingError: Error, Sendable, LocalizedError {
    /// The port value is not a valid 1–65535 integer.
    case invalidPort(String)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .invalidPort(value):
            "Invalid port '\(value)': expected an integer between 1 and 65535."
        }
    }

    /// A machine-readable reason label for diagnostics.
    public var reasonCode: String {
        switch self {
        case .invalidPort: "invalidPort"
        }
    }
}

/// The fully-resolved runner configuration after precedence resolution.
public struct RunnerConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let namespace: String
    public let scenario: Bool

    /// Resolves flags (highest priority), then environment, then defaults.
    ///
    /// - Parameters:
    ///   - flags: The parsed command-line flag values.
    ///   - environment: Process environment.
    /// - Returns: The resolved configuration.
    /// - Throws: `RunnerParsingError.invalidPort` when the effective port is
    ///   not a valid 1–65535 integer.
    public static func resolve(
        flags: RunnerParsingFlags,
        environment: [String: String]
    ) throws -> RunnerConfiguration {
        let host = flags.host
            ?? environment["GNOSTIC_HOST"]
            ?? "127.0.0.1"
        let namespace = flags.namespace
            ?? environment["GNOSTIC_NAMESPACE"]
            ?? "gnostic"

        let port: Int
        if let flag = flags.port {
            port = flag
        } else if let raw = environment["GNOSTIC_PORT"] {
            guard let parsed = Int(raw), (1...65535).contains(parsed) else {
                throw RunnerParsingError.invalidPort(raw)
            }
            port = parsed
        } else {
            port = 1883
        }
        guard (1...65535).contains(port) else {
            throw RunnerParsingError.invalidPort(String(port))
        }

        return RunnerConfiguration(
            host: host,
            port: port,
            namespace: namespace,
            scenario: false
        )
    }
}

/// The flag surface exposed by `GnosticRunner`, decoupled from the argument
/// scanner for testability.
public struct RunnerParsingFlags: Sendable {
    public var host: String?
    public var port: Int?
    public var namespace: String?

    public init(host: String? = nil, port: Int? = nil, namespace: String? = nil) {
        self.host = host
        self.port = port
        self.namespace = namespace
    }
}

@MainActor
final class RunnerRuntime {
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
