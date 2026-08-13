// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

/// Failures raised while materializing or running a validated node plan.
public enum NodeRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedAscendantKind(String)
    case unsupportedWorkspaceKind(String)
    case invalidWorkspaceURI(UUID)
    case missingTimeline(UUID)
    case missingWorkspace(UUID)
    case noOperatingAscendant(UUID)
    case unknownAscendant(UUID)
    case noConfiguredAscendant
    case ambiguousAscendant
    case turnFailed(String)
    case startInProgress
    case notRunning

    public var errorDescription: String? {
        switch self {
        case let .unsupportedAscendantKind(kind): "No Ascendant adapter is registered for '\(kind)'."
        case let .unsupportedWorkspaceKind(kind): "No Workspace adapter is registered for '\(kind)'."
        case let .invalidWorkspaceURI(id): "Workspace \(id.uuidString) has an invalid URI."
        case let .missingTimeline(id): "Timeline \(id.uuidString) is not in the launch plan."
        case let .missingWorkspace(id): "Workspace \(id.uuidString) is not in the launch plan."
        case let .noOperatingAscendant(id): "Timeline \(id.uuidString) has no operating Ascendant."
        case let .unknownAscendant(id): "Ascendant \(id.uuidString) is not in the launch plan."
        case .noConfiguredAscendant: "The node has no configured Ascendant."
        case .ambiguousAscendant: "The node has multiple Ascendants; select one explicitly."
        case let .turnFailed(detail): detail
        case .startInProgress: "The node runtime is already starting."
        case .notRunning: "The node runtime is not running."
        }
    }

    public var reasonCode: String {
        switch self {
        case .unsupportedAscendantKind: "unsupportedAscendantKind"
        case .unsupportedWorkspaceKind: "unsupportedWorkspaceKind"
        case .invalidWorkspaceURI: "invalidWorkspaceURI"
        case .missingTimeline: "missingTimeline"
        case .missingWorkspace: "missingWorkspace"
        case .noOperatingAscendant: "noOperatingAscendant"
        case .unknownAscendant: "unknownAscendant"
        case .noConfiguredAscendant: "noConfiguredAscendant"
        case .ambiguousAscendant: "ambiguousAscendant"
        case .turnFailed: "turnFailed"
        case .startInProgress: "startInProgress"
        case .notRunning: "notRunning"
        }
    }

    public var statusCode: Int {
        switch self {
        case .missingTimeline, .missingWorkspace, .unknownAscendant: 404
        case .noOperatingAscendant: 409
        case .startInProgress, .notRunning: 503
        case .turnFailed: 500
        default: 400
        }
    }
}

/// The observable, stable identity graph materialized by ``NodeRuntime``.
public struct NodeRuntimeSnapshot: Sendable, Equatable {
    public let nodeID: UUID
    public let ascendantIDs: [UUID]
    public let agentIDs: [UUID]
    public let timelineIDs: [UUID]
    public let operatedTimelineIDs: [UUID]
    public let workspaceIDs: [UUID]

    public init(nodeID: UUID, ascendantIDs: [UUID], agentIDs: [UUID], timelineIDs: [UUID], operatedTimelineIDs: [UUID], workspaceIDs: [UUID]) {
        self.nodeID = nodeID
        self.ascendantIDs = ascendantIDs
        self.agentIDs = agentIDs
        self.timelineIDs = timelineIDs
        self.operatedTimelineIDs = operatedTimelineIDs
        self.workspaceIDs = workspaceIDs
    }
}

/// A registry of downstream LLM adapters. GnosticCore owns the runtime shape;
/// the CLI may supply provider-specific language models without being imported by Core.
@MainActor public protocol AscendantRuntimeAdapter: AnyObject, Sendable {
    var identity: AscendantRuntimeIdentity { get }
    func timelines() async throws -> [AscendantRuntimeTimeline]
    func createTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline
    func removeTimeline(id: UUID) async
    func renameTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline
    func attachWorkspace(_ reference: WorkspaceReference, to timelineID: UUID) async throws
    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws
    func enabledToolIDs(for timelineID: UUID) async -> [String]
    func runTurn(_ request: AgentChatRequest, updates: AscendantTurnUpdateStore) async throws -> String
    func cancelAll() async
    func shutdown() async
}

/// Gnostic's stable, provider-independent projection of an Ascendant identity.
public struct AscendantRuntimeIdentity: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let description: String
    public let privateTimelineID: UUID
    public let primaryWorkspaceID: UUID?
    public let lastActiveAt: Date
    public let createdAt: Date
    public let updatedAt: Date
}

/// Gnostic's stable, provider-independent projection of a Timeline.
public struct AscendantRuntimeTimeline: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let attachedWorkspaceIDs: [UUID]
    public let attachedAgentInstanceID: UUID?
    public let isArchived: Bool
    public let isPrivate: Bool
    public let createdAt: Date
    public let updatedAt: Date
}

/// Construction dependencies supplied by the node composition boundary.  The
/// adapter owns all PositronicKit objects created from these values.
@MainActor public struct AscendantRuntimeDependencies {
    public let workspaces: [UUID: any Workspace]
    public let catalog: NetworkCatalog
    public let communication: CommunicationManager
    public let permissionCoordinator: AscendantPermissionCoordinator
    public init(workspaces: [UUID: any Workspace], catalog: NetworkCatalog, communication: CommunicationManager, permissionCoordinator: AscendantPermissionCoordinator) {
        self.workspaces = workspaces; self.catalog = catalog; self.communication = communication; self.permissionCoordinator = permissionCoordinator
    }
}

public struct AscendantAdapterRegistry: Sendable {
    public typealias Factory = @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ profile: NodeManifest.LLMProfile?, _ dependencies: AscendantRuntimeDependencies, _ timelines: [NodeManifest.Timeline], _ references: [UUID: WorkspaceReference]) async throws -> any AscendantRuntimeAdapter

    private var factories: [String: Factory]

    public init() {
        factories = ["positronic": { ascendant, profile, dependencies, timelines, references in
            try await PositronicAscendantAdapter(ascendant: ascendant, profile: profile, dependencies: dependencies, timelines: timelines, references: references, languageModel: UnconfiguredLLMService())
        }]
    }

    public mutating func register(kind: String, factory: @escaping Factory) {
        factories[kind] = factory
    }

    /// Transitional provider seam retained for CLI composition. It configures
    /// the Positronic adapter without exposing its construction to NodeRuntime.
    public mutating func register(kind: String, languageModel factory: @escaping @Sendable (_ ascendant: NodeManifest.Ascendant, _ profile: NodeManifest.LLMProfile?) -> any LanguageModel) {
        factories[kind] = { ascendant, profile, dependencies, timelines, references in
            try await PositronicAscendantAdapter(ascendant: ascendant, profile: profile, dependencies: dependencies, timelines: timelines, references: references, languageModel: factory(ascendant, profile))
        }
    }

    fileprivate func makeAdapter(for ascendant: NodeManifest.Ascendant, profile: NodeManifest.LLMProfile?, dependencies: AscendantRuntimeDependencies, timelines: [NodeManifest.Timeline], references: [UUID: WorkspaceReference]) async throws -> any AscendantRuntimeAdapter {
        guard let factory = factories[ascendant.kind] else { throw NodeRuntimeError.unsupportedAscendantKind(ascendant.kind) }
        return try await factory(ascendant, profile, dependencies, timelines, references)
    }

    fileprivate func validate(kinds: some Sequence<String>) throws {
        for kind in kinds where factories[kind] == nil {
            throw NodeRuntimeError.unsupportedAscendantKind(kind)
        }
    }
}

/// A registry of local Workspace adapters keyed by the manifest's `kind` field.
public struct WorkspaceAdapterRegistry: Sendable {
    public typealias Factory = @Sendable (_ configuration: NodeManifest.Workspace, _ reference: WorkspaceReference) throws -> any Workspace

    private var factories: [String: Factory]

    public init() {
        factories = ["echo": { _, reference in EchoWorkspace(reference: reference) }]
    }

    public mutating func register(kind: String, factory: @escaping Factory) {
        factories[kind] = factory
    }

    fileprivate func makeWorkspace(for configuration: NodeManifest.Workspace, reference: WorkspaceReference) throws -> any Workspace {
        guard let factory = factories[configuration.kind] else { throw NodeRuntimeError.unsupportedWorkspaceKind(configuration.kind) }
        return try factory(configuration, reference)
    }

    fileprivate func validate(kinds: some Sequence<String>) throws {
        for kind in kinds where factories[kind] == nil {
            throw NodeRuntimeError.unsupportedWorkspaceKind(kind)
        }
    }
}

/// Testable lifecycle seams used to prove startup rollback without depending
/// on a live broker failure. Production callers use the no-op default.
public struct NodeRuntimeLifecycleHooks: Sendable {
    public var afterConnection: @Sendable () throws -> Void
    public var afterRegistration: @Sendable () throws -> Void
    public var beforeAdvertisement: @Sendable () throws -> Void
    public var beforeDiscoverResponder: @Sendable () async throws -> Void
    public var afterDiscoverResponder: @Sendable () async throws -> Void
    public var afterAdvertisement: @Sendable () async throws -> Void

    public init(
        afterConnection: @escaping @Sendable () throws -> Void = {},
        afterRegistration: @escaping @Sendable () throws -> Void = {},
        beforeAdvertisement: @escaping @Sendable () throws -> Void = {},
        beforeDiscoverResponder: @escaping @Sendable () async throws -> Void = {},
        afterDiscoverResponder: @escaping @Sendable () async throws -> Void = {},
        afterAdvertisement: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.afterConnection = afterConnection
        self.afterRegistration = afterRegistration
        self.beforeAdvertisement = beforeAdvertisement
        self.beforeDiscoverResponder = beforeDiscoverResponder
        self.afterDiscoverResponder = afterDiscoverResponder
        self.afterAdvertisement = afterAdvertisement
    }
}

/// Dependency-injection boundary for NodeRuntime. The default registries are
/// deterministic and require no LLM or broker credentials.
public struct NodeRuntimeAdapters: Sendable {
    public var ascendants: AscendantAdapterRegistry
    public var workspaces: WorkspaceAdapterRegistry
    public var lifecycle: NodeRuntimeLifecycleHooks

    public init(
        ascendants: AscendantAdapterRegistry = .init(),
        workspaces: WorkspaceAdapterRegistry = .init(),
        lifecycle: NodeRuntimeLifecycleHooks = .init()
    ) {
        self.ascendants = ascendants
        self.workspaces = workspaces
        self.lifecycle = lifecycle
    }

    public static var `default`: NodeRuntimeAdapters { .init() }
}

/// A local echo Workspace implementation. All configured echo Workspaces use
/// the same multiplexed provider route while retaining their own stable IDs.
public struct EchoWorkspace: Workspace, Sendable {
    public let reference: WorkspaceReference
    public var id: UUID { reference.id }

    public init(reference: WorkspaceReference) { self.reference = reference }

    public func listTools() async throws -> [ToolReference] { reference.tools }

    public func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard id == NodeRuntime.echoToolID else { throw WorkspaceError.toolExecutionNotSupported }
        return .success(parameters["value"]?.value as? String ?? "")
    }

    public func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    public func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public func listFiles(path _: String) async throws -> [String] { throw WorkspaceError.toolExecutionNotSupported }
    public func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public func healthCheck() async -> Bool { true }
}

/// One unary Axoloty handler serving every local echo Workspace by workspace ID.
public actor MultiplexedWorkspaceProvider {
    public static let invocationOperation = WorkspaceProvider.invocationOperation

    private let workspaces: [UUID: any Workspace]
    private let isAvailable: @Sendable () async -> Bool

    public init(
        workspaces: [UUID: any Workspace],
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.workspaces = workspaces
        self.isAvailable = isAvailable
    }

    public func handle(parameters: String?, expectedProviderID: String? = nil) async throws -> CallHandlerResult {
        guard await isAvailable() else { throw NodeRuntimeError.notRunning }
        guard let parameters else { throw WorkspaceError.toolExecutionNotSupported }
        let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
        if let expectedProviderID, let providerID = invocation.providerID,
           providerID.lowercased() != expectedProviderID.lowercased() {
            throw WorkspaceError.connectionFailed
        }
        guard let workspace = workspaces[invocation.workspaceID] else {
            throw WorkspaceError.workspaceNotFound
        }
        let result = try await workspace.executeTool(id: invocation.toolID, parameters: invocation.arguments)
        return .success(result: String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        let providerID = communication.identity.objectId.string
        return try await communication.registerCallHandler(operation: Self.invocationOperation, context: communication.identity) { [self] request in
            try await handle(parameters: request.parameters, expectedProviderID: providerID)
        }
    }
}

/// Materializes a validated node manifest into one transport connection,
/// per-Ascendant runtime adapters, and complete canonical advertisements.
@MainActor
public final class NodeRuntime {
    private enum LifecycleState {
        case stopped
        case starting
        case running
        case closed
    }

    public nonisolated static let echoToolID = "workspace_echo"

    public let plan: NodeLaunchPlan
    public var launchPlan: NodeLaunchPlan { plan }
    public let host: String
    public let port: Int
    public let namespace: String
    public var isRunning: Bool { lifecycleState == .running }
    private var ascendantAdapters: [UUID: any AscendantRuntimeAdapter]
    /// Canonical domain state. Adapter persistence and network objects are
    /// projections of the records accepted by this actor.
    private let registry: NodeRegistry

    private let container: Container
    private let communication: CommunicationManager
    private let lifecycle: ObjectLifecycleController
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let adapters: NodeRuntimeAdapters
    private var workspaceReferences: [UUID: WorkspaceReference]
    private let localWorkspaces: [UUID: any Workspace]
    private var provider: MultiplexedWorkspaceProvider?
    private var registrations: [CallHandlerRegistration] = []
    private var discoverResponder: DiscoverResponderRegistration?
    private var lifecycleState: LifecycleState = .stopped
    private let turnCoordinator: AscendantTurnCoordinator
    private let turnUpdates: AscendantTurnUpdateStore
    private let permissionCoordinator: AscendantPermissionCoordinator
    private var permissionResponseTask: Task<Void, Never>?
    private var turnUpdatePublishTask: Task<Void, Never>?
    private var networkResolutionTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var shutdownTask: Task<Void, Never>?
    private var advertisedObjects: [String: CoatyObject] = [:]

    public init(plan: NodeLaunchPlan, adapters: NodeRuntimeAdapters = .default) async throws {
        try NodeRuntime.validate(plan: plan)
        self.plan = plan
        host = plan.broker.host
        port = plan.broker.port
        namespace = plan.broker.namespace
        self.adapters = adapters
        ascendantAdapters = [:]
        let updates = AscendantTurnUpdateStore()
        turnUpdates = updates
        permissionCoordinator = AscendantPermissionCoordinator(updates: updates)
        turnCoordinator = AscendantTurnCoordinator()

        try adapters.ascendants.validate(kinds: plan.ascendants.map(\.kind))
        try adapters.workspaces.validate(kinds: plan.workspaces.map(\.kind))

        var references: [UUID: WorkspaceReference] = [:]
        var workspaces: [UUID: any Workspace] = [:]
        for configuration in plan.workspaces {
            guard let uri = WorkspaceURI(parsing: configuration.uri) else { throw NodeRuntimeError.invalidWorkspaceURI(configuration.id) }
            let provisionalReference = WorkspaceReference(
                id: configuration.id,
                uri: uri,
                location: .runtime,
                tools: [.custom(Self.echoToolDefinition(for: configuration))]
            )
            let workspace = try adapters.workspaces.makeWorkspace(
                for: configuration,
                reference: provisionalReference
            )
            let reference = WorkspaceReference(
                id: configuration.id,
                uri: uri,
                location: .runtime,
                tools: try await workspace.listTools()
            )
            references[configuration.id] = reference
            workspaces[configuration.id] = workspace
        }
        for timeline in plan.timelines {
            for attachment in timeline.attachments where attachment.scope == .network {
                guard let uriString = attachment.uri, let uri = WorkspaceURI(parsing: uriString) else {
                    throw NodeRuntimeError.invalidWorkspaceURI(attachment.workspaceID)
                }
                references[attachment.workspaceID] = WorkspaceReference(
                    id: attachment.workspaceID,
                    uri: uri,
                    location: .attached,
                    tools: []
                )
            }
        }
        workspaceReferences = references
        localWorkspaces = workspaces
        provider = nil

        let resolvedContainer = try Container.resolve(
            components: Components(
                controllers: ["ObjectLifecycleController": ObjectLifecycleController.self],
                objectTypes: [GnosticAgentObject.self, GnosticTimelineObject.self, GnosticWorkspaceObject.self]
            ),
            configuration: Configuration(
                common: CommonOptions(agentIdentity: ["name": "gnostic-node-\(plan.nodeID.uuidString.lowercased())"]),
                communication: CommunicationOptions(
                    namespace: plan.broker.namespace,
                    shouldEnableCrossNamespacing: false,
                    mqttClientOptions: Self.mqttOptions(for: plan.broker),
                    shouldAutoStart: false
                )
            )
        )
        guard let communicationManager = resolvedContainer.communicationManager,
              let lifecycleController = resolvedContainer.getController(name: "ObjectLifecycleController") as? ObjectLifecycleController
        else {
            resolvedContainer.shutdown()
            throw NodeRuntimeError.notRunning
        }
        container = resolvedContainer
        let objectCatalog = NetworkCatalog()
        communication = communicationManager
        lifecycle = lifecycleController
        catalog = objectCatalog
        subscription = GnosticSubscription(catalog: objectCatalog, communicationManager: communicationManager)

        do {
            var operatedTimelines: [AscendantRuntimeTimeline] = []
            for ascendant in plan.ascendants {
                let profile = ascendant.llmProfileID.flatMap { id in plan.llmProfiles.first(where: { $0.id == id }) }
                let timelineConfigurations = plan.timelines.filter { $0.operatingAscendantID == ascendant.id }
                let dependencies = AscendantRuntimeDependencies(workspaces: workspaces, catalog: catalog, communication: communication, permissionCoordinator: permissionCoordinator)
                let adapter = try await adapters.ascendants.makeAdapter(for: ascendant, profile: profile, dependencies: dependencies, timelines: timelineConfigurations, references: references)
                ascendantAdapters[ascendant.id] = adapter
                operatedTimelines += try await adapter.timelines()
            }
            registry = try NodeRegistry(
                plan: plan,
                operatedTimelines: operatedTimelines
            )
            if !workspaces.isEmpty {
                provider = MultiplexedWorkspaceProvider(workspaces: workspaces) { [weak self] in
                    await self?.isRunning == true
                }
            }
        } catch {
            for adapter in ascendantAdapters.values {
                await adapter.shutdown()
            }
            ascendantAdapters.removeAll()
            container.shutdown()
            throw error
        }
    }

    public convenience init(launchPlan: NodeLaunchPlan, adapters: NodeRuntimeAdapters = .default) async throws {
        try await self.init(plan: launchPlan, adapters: adapters)
    }

    public func start() async throws {
        switch lifecycleState {
        case .running:
            return
        case .starting:
            throw NodeRuntimeError.startInProgress
        case .closed:
            throw NodeRuntimeError.notRunning
        case .stopped:
            lifecycleState = .starting
        }

        let startup = Task { @MainActor [weak self] in
            guard let self else { throw NodeRuntimeError.notRunning }
            try await self.performStart()
        }
        startupTask = startup
        do {
            try await startup.value
            startupTask = nil
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func performStart() async throws {
        do {
            try await container.startAndWaitUntilReady()
            try requireActiveStart()
            try adapters.lifecycle.afterConnection()
            try await subscription.start()
            try requireActiveStart()
            startNetworkResolution()
            if let provider { registrations.append(try await provider.register(on: communication)) }

            let agentChat = AgentChatProvider(
                execute: { [weak self] request in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    return try await self.chat(request)
                },
                replayStore: turnUpdates,
                isAvailable: { [weak self] in await self?.isRunning == true }
            )
            registrations.append(try await agentChat.register(on: communication, context: communication.identity))
            registrations.append(try await agentChat.registerReplay(on: communication, context: communication.identity))
            let permission = AgentPermissionProvider(coordinator: permissionCoordinator)
            registrations.append(try await permission.register(on: communication, context: communication.identity))
            permissionResponseTask = try await permission.observeResponses(
                on: communication,
                providerID: communication.identity.objectId.string
            )

            let events = await turnUpdates.events()
            turnUpdatePublishTask = Task { [communication] in
                for await event in events {
                    guard let channel = try? AgentChatProvider.updateEvent(event) else { continue }
                    communication.publishChannel(channel)
                }
            }

            let status = TimelineStatusProvider { [weak self] request in
                guard let self else { throw NodeRuntimeError.notRunning }
                guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                return try await self.timelineStatus(for: request.timelineID)
            }
            registrations.append(try await status.register(on: communication, context: communication.identity))

            let management = TimelineManagementProvider(
                create: { [weak self] title, ascendantID in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                    let selectedID = try await self.selectedAscendantID(requested: ascendantID)
                    return try await self.createTimeline(title: title, ascendantID: selectedID)
                },
                list: { [weak self] in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                    return try await self.listTimelines()
                },
                update: { [weak self] request in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                    return try await self.renameTimeline(request)
                }
            )
            registrations += try await management.register(on: communication, context: communication.identity)

            let operations = WorkspaceOpsProvider(
                list: { [weak self] in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                    return await self.attachableWorkspaces()
                },
                attach: { [weak self] request in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                    return try await self.attachWorkspace(request)
                },
                detach: { [weak self] request in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                    return try await self.detachWorkspace(request)
                }
            )
            registrations += try await operations.register(on: communication, context: communication.identity)
            try requireActiveStart()
            try adapters.lifecycle.afterRegistration()
            try await adapters.lifecycle.beforeDiscoverResponder()
            discoverResponder = await communication.registerDiscoverResponder { [weak self] request in
                guard let self else { return }
                try await self.respond(to: request)
            }
            try await adapters.lifecycle.afterDiscoverResponder()
            try requireActiveStart()
            try adapters.lifecycle.beforeAdvertisement()
            lifecycleState = .running
            await advertiseAll()
            try await adapters.lifecycle.afterAdvertisement()
            try requireActiveRunningStart()
        } catch {
            await rollbackStart(close: true)
            throw error
        }
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard lifecycleState != .closed else { return }
        lifecycleState = .closed

        let startup = startupTask
        let cleanup = Task { @MainActor [weak self, startup] in
            startup?.cancel()
            guard let self else { return }
            if let startup {
                let result = await startup.result
                if case .success = result {
                    await self.rollbackStart(close: true)
                }
            } else {
                await self.rollbackStart(close: true)
            }
        }
        shutdownTask = cleanup
        await cleanup.value
        shutdownTask = nil
    }

    public func snapshot() async -> NodeRuntimeSnapshot {
        await registry.snapshot()
    }

    public func advertisedWorkspaceIDs() -> [UUID] {
        plan.workspaces
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    public func timeline(id: UUID) async -> AscendantRuntimeTimeline? {
        await registry.timeline(id: id)?.timeline
    }

    /// Returns the Ascendant selected to operate a timeline, including
    /// process-only timelines created after launch.
    public func ascendantID(forTimeline timelineID: UUID) async -> UUID? {
        await registry.operatorID(forTimeline: timelineID)
    }

    private func selectedAscendantID(requested ascendantID: UUID?) throws -> UUID {
        if let ascendantID {
            guard ascendantAdapters[ascendantID] != nil else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
            return ascendantID
        }
        guard !ascendantAdapters.isEmpty else { throw NodeRuntimeError.noConfiguredAscendant }
        guard ascendantAdapters.count == 1 else { throw NodeRuntimeError.ambiguousAscendant }
        return ascendantAdapters.keys[...].first!
    }

    public func workspaceReference(id: UUID) async -> WorkspaceReference? {
        guard let record = await registry.workspace(id: id),
              let reference = workspaceReferences[id],
              reference.uri.description == record.uri,
              record.isAvailable || reference.tools.isEmpty else { return nil }
        return reference
    }

    public func executeWorkspaceTool(workspaceID: UUID, toolID: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard isRunning else { throw NodeRuntimeError.notRunning }
        guard let workspace = localWorkspaces[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
        return try await workspace.executeTool(id: toolID, parameters: arguments)
    }

    /// Returns the tool identifiers currently available to an operated Timeline.
    public func enabledToolIDs(for timelineID: UUID) async throws -> [String] {
        guard let ascendantID = await ascendantID(forTimeline: timelineID),
              let adapter = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(timelineID)
        }
        return await adapter.enabledToolIDs(for: timelineID)
    }

    /// Runs one chat turn against the adapter selected by the
    /// addressed timeline. Unoperated timelines remain observable but cannot
    /// accidentally fall through to an arbitrary Ascendant.
    public func chat(_ request: AgentChatRequest) async throws -> AgentChatResult {
        guard lifecycleState != .closed else { throw NodeRuntimeError.notRunning }
        guard let ascendantID = await ascendantID(forTimeline: request.timelineID) else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        guard isRunning else { throw NodeRuntimeError.notRunning }
        guard let runtime = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        return try await turnCoordinator.execute(request) { [runtime, turnUpdates] in
            try await runtime.runTurn(request, updates: turnUpdates)
        }
    }

    /// Creates a timeline in the selected Ascendant's in-memory runtime. It
    /// is intentionally absent from the launch plan and therefore process-only.
    @discardableResult
    public func createTimeline(title: String, ascendantID: UUID) async throws -> TimelineStatus {
        guard lifecycleState != .closed else { throw NodeRuntimeError.notRunning }
        guard let runtime = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        let reservation = try await registry.registerRuntimeTimeline(title: title, ascendantID: ascendantID)
        var projectedID = reservation.id
        do {
            let timeline = try await runtime.createTimeline(id: reservation.id, title: title)
            projectedID = timeline.id
            _ = try await registry.replaceTimeline(timeline)
            if isRunning { advertise(GnosticTimelineObject(timeline: timeline)) }
            return Self.mapTimeline(timeline)
        } catch {
            if projectedID != reservation.id { await runtime.removeTimeline(id: projectedID) }
            await runtime.removeTimeline(id: reservation.id)
            await registry.removeRuntimeTimeline(id: reservation.id)
            throw error
        }
    }

    public func listTimelines() async throws -> [TimelineStatus] {
        guard lifecycleState != .closed else { throw NodeRuntimeError.notRunning }
        return await registry.listTimelines().map(Self.mapTimeline)
    }

    private func timelineStatus(for timelineID: UUID) async throws -> TimelineStatus {
        guard let timeline = await registry.timeline(id: timelineID) else { throw NodeRuntimeError.missingTimeline(timelineID) }
        return Self.mapTimeline(timeline.timeline)
    }

    private func renameTimeline(_ request: TimelineUpdateRequest) async throws -> TimelineStatus {
        guard let ascendantID = await ascendantID(forTimeline: request.timelineID),
              let runtime = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        let previous = await registry.timeline(id: request.timelineID)?.timeline
        let timeline = try await runtime.renameTimeline(id: request.timelineID, title: request.title)
        do {
            _ = try await registry.replaceTimeline(timeline) { @MainActor [weak self] record in
                guard let self, self.lifecycleState == .running else { return }
                self.lifecycle.readvertiseDiscoverableObject(object: GnosticTimelineObject(timeline: record.timeline))
            }
            return Self.mapTimeline(timeline)
        } catch {
            if let previous { _ = try? await runtime.renameTimeline(id: previous.id, title: previous.title) }
            throw error
        }
    }

    private func attachableWorkspaces() async -> [WorkspaceListing] {
        var listings = Dictionary(uniqueKeysWithValues: plan.workspaces.map {
            ($0.id, WorkspaceListing(id: $0.id, name: $0.name, isAvailable: true))
        })
        for entry in await catalog.networkObjects()
            where entry.objectType == GnosticObjectType.workspace
                && entry.workspace?.isAvailable == true
                && listings[entry.objectID] == nil {
            guard case .available = await catalog.workspaceAttachmentStatus(id: entry.objectID) else { continue }
            listings[entry.objectID] = WorkspaceListing(id: entry.objectID, name: entry.name, isAvailable: true)
        }
        return listings.values.sorted { ($0.id.uuidString, $0.name) < ($1.id.uuidString, $1.name) }
    }

    private func attachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool {
        guard let ascendantID = await ascendantID(forTimeline: request.timelineID),
              let runtime = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        if localWorkspaces[request.workspaceID] != nil,
           let reference = workspaceReferences[request.workspaceID] {
            try await runtime.attachWorkspace(reference, to: request.timelineID)
        } else {
            guard let reference = try await resolveNetworkWorkspace(workspaceID: request.workspaceID) as WorkspaceReference? else { throw NodeRuntimeError.missingWorkspace(request.workspaceID) }
            try await runtime.attachWorkspace(reference, to: request.timelineID)
        }
        if let timeline = try await runtime.timelines().first(where: { $0.id == request.timelineID }) {
            do {
                _ = try await registry.replaceTimeline(timeline) { @MainActor [weak self] record in
                    guard let self, self.lifecycleState == .running else { return }
                    self.lifecycle.readvertiseDiscoverableObject(object: GnosticTimelineObject(timeline: record.timeline))
                }
            } catch {
                try? await runtime.detachWorkspace(request.workspaceID, from: request.timelineID)
                throw error
            }
        }
        return true
    }

    private func detachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool {
        guard let ascendantID = await ascendantID(forTimeline: request.timelineID),
              let runtime = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        let previousReference = workspaceReferences[request.workspaceID]
        try await runtime.detachWorkspace(request.workspaceID, from: request.timelineID)
        if let timeline = try await runtime.timelines().first(where: { $0.id == request.timelineID }) {
            do {
                _ = try await registry.replaceTimeline(timeline) { @MainActor [weak self] record in
                    guard let self, self.lifecycleState == .running else { return }
                    self.lifecycle.readvertiseDiscoverableObject(object: GnosticTimelineObject(timeline: record.timeline))
                }
            } catch {
                if let previousReference { try? await runtime.attachWorkspace(previousReference, to: request.timelineID) }
                throw error
            }
        }
        return true
    }

    /// Discovers and imports a network Workspace only when a caller needs it.
    /// Construction and startup never resolve network attachments.
    @discardableResult
    public func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> WorkspaceReference {
        guard isRunning else { throw NodeRuntimeError.notRunning }
        await subscription.discover(using: communication, timeout: timeout)
        let status = await catalog.workspaceAttachmentStatus(id: workspaceID)
        guard case let .available(_, uri) = status,
              let descriptor = await catalog.networkObjects().first(where: {
                  $0.objectID == workspaceID && $0.workspace?.uri == uri
              })?.workspace,
              let reference = try? WorkspaceReferenceProjection.reference(from: descriptor)
        else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        if let configured = await registry.workspace(id: workspaceID), configured.uri != uri {
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        try await installResolvedNetworkWorkspace(reference, workspaceID: workspaceID)
        return reference
    }

    public func networkAttachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await catalog.workspaceAttachmentStatus(id: workspaceID)
    }

    private func advertiseAll() async {
        for runtime in ascendantAdapters.values {
            advertise(GnosticAgentObject(identity: runtime.identity))
        }
        for timeline in await registry.listTimelines() { advertise(GnosticTimelineObject(timeline: timeline)) }
        for workspace in plan.workspaces {
            if let reference = workspaceReferences[workspace.id] {
                advertise(GnosticWorkspaceObject(workspace: reference))
            }
        }
    }

    private func respond(to request: DiscoverRequest) async throws {
        guard isRunning else { return }
        let types = request.snapshot.objectTypes
        for object in await discoverableObjects() where types == nil || types?.contains(object.objectType) == true { try request.resolve(object: object) }
    }

    private func discoverableObjects() async -> [CoatyObject] {
        var objects: [CoatyObject] = []
        for runtime in ascendantAdapters.values {
            objects.append(GnosticAgentObject(identity: runtime.identity))
        }
        objects += await registry.listTimelines().map(GnosticTimelineObject.init)
        objects += workspaceReferences.values
            .filter { reference in plan.workspaces.contains(where: { $0.id == reference.id }) }
            .map(GnosticWorkspaceObject.init)
        return objects
    }

    private func advertise(_ object: CoatyObject) {
        advertisedObjects[object.objectId.string] = object
        lifecycle.advertiseDiscoverableObject(object: object)
    }

    private func startNetworkResolution() {
        networkResolutionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.lifecycleState != .closed else { return }
                await self.subscription.discover(using: self.communication, timeout: .milliseconds(250))
                for workspaceID in await self.registry.unresolvedWorkspaceIDs() {
                    _ = try? await self.resolveAvailableNetworkWorkspace(workspaceID)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @discardableResult
    private func resolveAvailableNetworkWorkspace(_ workspaceID: UUID) async throws -> WorkspaceReference? {
        guard let expectedURI = await registry.workspace(id: workspaceID)?.uri else { return nil }
        let status = await catalog.workspaceAttachmentStatus(id: workspaceID)
        guard case let .available(_, uri) = status, uri == expectedURI,
              let descriptor = await catalog.networkObjects().first(where: {
                  $0.objectID == workspaceID && $0.workspace?.uri == uri
              })?.workspace,
              let reference = try? WorkspaceReferenceProjection.reference(from: descriptor)
        else { return nil }
        try await installResolvedNetworkWorkspace(reference, workspaceID: workspaceID)
        return reference
    }

    private func installResolvedNetworkWorkspace(_ reference: WorkspaceReference, workspaceID: UUID) async throws {
        let attachedTimelines = plan.timelines.filter {
            $0.attachments.contains { $0.workspaceID == workspaceID && $0.scope == .network }
        }
        for ascendantID in Set(attachedTimelines.compactMap(\.operatingAscendantID)) {
            guard let runtime = ascendantAdapters[ascendantID] else { continue }
            for timeline in attachedTimelines where timeline.operatingAscendantID == ascendantID {
                // PositronicKit intentionally permits attaching an existing ID;
                // doing so refreshes any already-hydrated tool registry with the
                // newly resolved remote Workspace implementation.
                try await runtime.attachWorkspace(reference, to: timeline.id)
            }
        }
        // Publish the resolved descriptor only after every owning adapter has
        // installed it, so callers never observe a half-resolved attachment.
        guard try await registry.resolveLazyWorkspace(
            id: workspaceID,
            uri: reference.uri.description,
            toolIDs: reference.tools.map(\.toolID)
        ) else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        workspaceReferences[workspaceID] = reference
    }

    private func requireActiveStart() throws {
        guard lifecycleState == .starting, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func requireActiveRunningStart() throws {
        guard lifecycleState == .running, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func rollbackStart(close: Bool) async {
        discoverResponder?.cancel(); discoverResponder = nil
        registrations.forEach { $0.cancel() }
        registrations.removeAll()
        let responseTask = permissionResponseTask
        let publishTask = turnUpdatePublishTask
        let resolutionTask = networkResolutionTask
        responseTask?.cancel(); permissionResponseTask = nil
        publishTask?.cancel(); turnUpdatePublishTask = nil
        resolutionTask?.cancel(); networkResolutionTask = nil
        for adapter in ascendantAdapters.values { await adapter.cancelAll() }
        await turnCoordinator.cancelAll()
        for adapter in ascendantAdapters.values { await adapter.shutdown() }
        await permissionCoordinator.denyAll(reason: "connection_lost")
        await responseTask?.value
        await publishTask?.value
        await resolutionTask?.value
        subscription.stop()
        advertisedObjects.values.forEach { lifecycle.deadvertiseDiscoverableObject(object: $0) }
        advertisedObjects.removeAll()
        container.shutdown()
        lifecycleState = close ? .closed : .stopped
    }

    private static func validate(plan: NodeLaunchPlan) throws {
        let manifest = NodeManifest(schemaVersion: NodeManifest.currentSchemaVersion, broker: plan.broker, node: plan.node, llmProfiles: plan.llmProfiles, ascendants: plan.ascendants, timelines: plan.timelines, workspaces: plan.workspaces)
        try manifest.validate()
    }

    private static func timeline(from configuration: NodeManifest.Timeline, agentID: UUID?) throws -> AscendantRuntimeTimeline {
        let now = Date()
        return .init(id: configuration.id, title: configuration.title, attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID), attachedAgentInstanceID: agentID, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
    }

    private static func mapTimeline(_ timeline: AscendantRuntimeTimeline) -> TimelineStatus {
        TimelineStatus(
            timelineID: timeline.id,
            title: timeline.title,
            attachedWorkspaceIDs: timeline.attachedWorkspaceIDs,
            isArchived: timeline.isArchived,
            isPrivate: timeline.isPrivate
        )
    }

    private static func mqttOptions(for broker: NodeManifest.Broker) -> MQTTClientOptions {
        let options = MQTTClientOptions(host: broker.host, port: UInt16(clamping: broker.port), shouldTryMDNSDiscovery: false, autoReconnect: false)
        options.username = broker.username; options.password = broker.password
        return options
    }

    private static func echoToolDefinition(for _: NodeManifest.Workspace) -> WorkspaceToolDefinition {
        WorkspaceToolDefinition(id: echoToolID, name: "Workspace echo", description: "Echoes a value from the workspace.", parametersSchema: ["type": AnyCodable("object"), "properties": AnyCodable(["value": AnyCodable(["type": AnyCodable("string")])]), "required": AnyCodable(["value"]), "additionalProperties": AnyCodable(false)])
    }
}

struct RuntimeWorkspaceFactory: WorkspaceFactory, Sendable {
    let local: [UUID: any Workspace]
    let remote: AxolotyWorkspaceFactory
    func create(from reference: WorkspaceReference) throws -> any Workspace {
        if let workspace = local[reference.id] { return workspace }
        return try remote.create(from: reference)
    }
}
