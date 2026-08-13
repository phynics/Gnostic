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
        case .turnFailed: "turnFailed"
        case .startInProgress: "startInProgress"
        case .notRunning: "notRunning"
        }
    }

    public var statusCode: Int {
        switch self {
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
public struct AscendantAdapterRegistry: Sendable {
    public typealias Factory = @Sendable (_ ascendant: NodeManifest.Ascendant, _ profile: NodeManifest.LLMProfile?) -> any LanguageModel

    private var factories: [String: Factory]

    public init() {
        factories = ["positronic": { _, _ in UnconfiguredLLMService() }]
    }

    public mutating func register(kind: String, factory: @escaping Factory) {
        factories[kind] = factory
    }

    fileprivate func makeLanguageModel(for ascendant: NodeManifest.Ascendant, profile: NodeManifest.LLMProfile?) throws -> any LanguageModel {
        guard let factory = factories[ascendant.kind] else { throw NodeRuntimeError.unsupportedAscendantKind(ascendant.kind) }
        return factory(ascendant, profile)
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

/// A stable PositronicKit runtime seeded from one manifest Ascendant.
public struct AscendantRuntime: Sendable {
    public let id: UUID
    public let agent: AgentInstance
    public let kit: PositronicKit

    public var timelineManager: TimelineManager { kit.timelineManager }

    fileprivate init(id: UUID, agent: AgentInstance, kit: PositronicKit) {
        self.id = id
        self.agent = agent
        self.kit = kit
    }
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
/// per-Ascendant PositronicKit runtimes, and complete canonical advertisements.
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
    public private(set) var ascendantRuntimes: [UUID: AscendantRuntime]

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
    private var unoperatedTimelines: [UUID: Timeline]
    private var runtimeTimelines: [UUID: UUID]
    private var runtimeTimelineRecords: [UUID: Timeline]
    private var timelineRecords: [UUID: Timeline]
    private var timelineStores: [UUID: InMemoryTimelinePersistence]
    private var networkToolsByAscendant: [UUID: [AnyTool]]
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
        ascendantRuntimes = [:]
        unoperatedTimelines = [:]
        runtimeTimelines = [:]
        runtimeTimelineRecords = [:]
        timelineRecords = [:]
        timelineStores = [:]
        networkToolsByAscendant = [:]
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
            let reference = WorkspaceReference(
                id: configuration.id,
                uri: uri,
                location: .runtime,
                tools: [.custom(Self.echoToolDefinition(for: configuration))]
            )
            references[configuration.id] = reference
            workspaces[configuration.id] = try adapters.workspaces.makeWorkspace(for: configuration, reference: reference)
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
            for ascendant in plan.ascendants {
                let profile = ascendant.llmProfileID.flatMap { id in plan.llmProfiles.first(where: { $0.id == id }) }
                let languageModel = try adapters.ascendants.makeLanguageModel(for: ascendant, profile: profile)
                let timelineConfigurations = plan.timelines.filter { $0.operatingAscendantID == ascendant.id }
                guard timelineConfigurations.contains(where: { $0.id == ascendant.defaultTimelineID }) else { throw NodeRuntimeError.missingTimeline(ascendant.defaultTimelineID) }
                let stores = (InMemoryAgentInstanceStore(), InMemoryTimelinePersistence(), InMemoryMessageStore(), InMemoryWorkspacePersistence(), InMemoryToolPersistence())
                let agent = AgentInstance(id: ascendant.id, name: ascendant.name, description: ascendant.description, privateTimelineID: ascendant.defaultTimelineID, metadata: ascendant.metadata.mapValues { AnyCodable($0) })
                try await stores.0.saveAgentInstance(agent)
                for configuration in timelineConfigurations {
                    let timeline = try Self.timeline(from: configuration, agentID: ascendant.id)
                    try await stores.1.saveTimeline(timeline)
                    timelineRecords[timeline.id] = timeline
                    for workspaceID in configuration.attachments.map(\.workspaceID) {
                        guard let reference = references[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
                        try await stores.3.saveWorkspace(reference)
                    }
                }
                let factory = RuntimeWorkspaceFactory(
                    local: workspaces,
                    remote: AxolotyWorkspaceFactory(catalog: catalog, communication: communication)
                )
                let kit = PositronicKit(configuration: .init(
                    provider: .init(languageModel: languageModel),
                    persistence: .init(messageStore: stores.2, timelinePersistence: stores.1, workspacePersistence: stores.3, toolPersistence: stores.4, agentInstanceStore: stores.0),
                    runtime: .init(
                        workspaceCreator: factory,
                        runtimeToolPolicy: .init(
                            installFilesystemTools: false,
                            installTimelineObservationTools: true,
                            installTimelineSendTool: true
                        ),
                        toolApprovalPolicy: AscendantToolApprovalPolicy(coordinator: permissionCoordinator)
                    )
                ))
                ascendantRuntimes[ascendant.id] = AscendantRuntime(id: ascendant.id, agent: agent, kit: kit)
                timelineStores[ascendant.id] = stores.1
                let attachmentService = DiscoveredWorkspaceAttachmentService(
                    catalog: catalog,
                    timelineManager: kit.timelineManager,
                    allowedTimelineIDs: Set(timelineConfigurations.map(\.id))
                )
                networkToolsByAscendant[ascendant.id] = [
                    ListNetworkObjectsTool(service: attachmentService).toAnyTool(),
                    InspectNetworkObjectTool(service: attachmentService).toAnyTool(),
                    AttachWorkspaceTool(service: attachmentService).toAnyTool(),
                ]
            }
            for configuration in plan.timelines where configuration.operatingAscendantID == nil {
                let timeline = try Self.timeline(from: configuration, agentID: nil)
                unoperatedTimelines[configuration.id] = timeline
                timelineRecords[timeline.id] = timeline
            }
            if !workspaces.isEmpty {
                provider = MultiplexedWorkspaceProvider(workspaces: workspaces) { [weak self] in
                    await self?.isRunning == true
                }
            }
        } catch {
            ascendantRuntimes.removeAll()
            unoperatedTimelines.removeAll()
            timelineRecords.removeAll()
            timelineStores.removeAll()
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
            registrations.append(try await agentChat.register(on: communication))
            registrations.append(try await agentChat.registerReplay(on: communication))
            let permission = AgentPermissionProvider(coordinator: permissionCoordinator)
            registrations.append(try await permission.register(on: communication))
            permissionResponseTask = try await permission.observeResponses(on: communication)

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
            registrations.append(try await status.register(on: communication))

            let management = TimelineManagementProvider(
                create: { [weak self] title, ascendantID in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    guard await self.isRunning else { throw NodeRuntimeError.notRunning }
                    let selectedID = await self.selectedAscendantID(requested: ascendantID)
                    guard let selectedID else {
                        throw NodeRuntimeError.noConfiguredAscendant
                    }
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
            registrations += try await management.register(on: communication)

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
            registrations += try await operations.register(on: communication)
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
            advertiseAll()
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

    public func snapshot() -> NodeRuntimeSnapshot {
        let networkWorkspaceIDs = plan.timelines
            .flatMap(\.attachments)
            .filter { $0.scope == .network }
            .map(\.workspaceID)
        return NodeRuntimeSnapshot(
            nodeID: plan.nodeID,
            ascendantIDs: plan.ascendants.map(\.id),
            agentIDs: plan.ascendants.map(\.id),
            timelineIDs: plan.timelines.map(\.id) + runtimeTimelineRecords.keys.sorted { $0.uuidString < $1.uuidString },
            operatedTimelineIDs: plan.timelines.filter { $0.operatingAscendantID != nil }.map(\.id) + runtimeTimelineRecords.keys.sorted { $0.uuidString < $1.uuidString },
            workspaceIDs: plan.workspaces.map(\.id) + networkWorkspaceIDs
        )
    }

    public func advertisedWorkspaceIDs() -> [UUID] {
        plan.workspaces
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    public func ascendantRuntime(id: UUID) -> AscendantRuntime? { ascendantRuntimes[id] }

    public func timeline(id: UUID) -> Timeline? {
        timelineRecords[id]
    }

    /// Returns the Ascendant selected to operate a timeline, including
    /// process-only timelines created after launch.
    public func ascendantID(forTimeline timelineID: UUID) -> UUID? {
        if let ascendantID = runtimeTimelines[timelineID] { return ascendantID }
        return plan.timelines.first(where: { $0.id == timelineID })?.operatingAscendantID
    }

    private func selectedAscendantID(requested ascendantID: UUID?) -> UUID? {
        if let ascendantID { return ascendantID }
        guard ascendantRuntimes.count == 1 else { return nil }
        return ascendantRuntimes.keys.first
    }

    public func workspaceReference(id: UUID) -> WorkspaceReference? { workspaceReferences[id] }

    public func executeWorkspaceTool(workspaceID: UUID, toolID: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard isRunning else { throw NodeRuntimeError.notRunning }
        guard let workspace = localWorkspaces[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
        return try await workspace.executeTool(id: toolID, parameters: arguments)
    }

    /// Runs one chat turn against the PositronicKit runtime selected by the
    /// addressed timeline. Unoperated timelines remain observable but cannot
    /// accidentally fall through to an arbitrary Ascendant.
    public func chat(_ request: AgentChatRequest) async throws -> AgentChatResult {
        guard lifecycleState != .closed else { throw NodeRuntimeError.notRunning }
        guard let ascendantID = ascendantID(forTimeline: request.timelineID) else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        guard isRunning else { throw NodeRuntimeError.notRunning }
        guard let runtime = ascendantRuntimes[ascendantID] else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        let networkTools = networkToolsByAscendant[ascendantID] ?? []
        return try await turnCoordinator.execute(request) { [runtime, turnUpdates, networkTools] in
            try await Self.runTurn(
                kit: runtime.kit,
                timelineID: request.timelineID,
                message: request.message,
                clientTurnID: request.clientTurnID,
                updates: turnUpdates,
                additionalTools: networkTools
            )
        }
    }

    /// Creates a timeline in the selected Ascendant's in-memory runtime. It
    /// is intentionally absent from the launch plan and therefore process-only.
    @discardableResult
    public func createTimeline(title: String, ascendantID: UUID) async throws -> TimelineStatus {
        guard lifecycleState != .closed else { throw NodeRuntimeError.notRunning }
        guard let runtime = ascendantRuntimes[ascendantID] else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        let timeline = Timeline(
            id: UUID.makeVersion4(),
            title: title,
            attachedAgentInstanceID: ascendantID,
            isPrivate: false
        )
        guard let timelineStore = timelineStores[ascendantID] else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        try await timelineStore.saveTimeline(timeline)
        try await runtime.timelineManager.ensureTimelineExists(id: timeline.id)
        runtimeTimelines[timeline.id] = ascendantID
        runtimeTimelineRecords[timeline.id] = timeline
        timelineRecords[timeline.id] = timeline
        if isRunning {
            advertise(GnosticTimelineObject(timeline: timeline))
        }
        return Self.mapTimeline(timeline)
    }

    public func listTimelines() async throws -> [TimelineStatus] {
        guard lifecycleState != .closed else { throw NodeRuntimeError.notRunning }
        var result: [TimelineStatus] = []
        for timeline in unoperatedTimelines.values { result.append(Self.mapTimeline(timeline)) }
        for runtime in ascendantRuntimes.values {
            result += try await runtime.timelineManager.listTimelines().map(Self.mapTimeline)
        }
        return result.sorted { $0.timelineID.uuidString < $1.timelineID.uuidString }
    }

    private func timelineStatus(for timelineID: UUID) async throws -> TimelineStatus {
        if let timeline = unoperatedTimelines[timelineID] { return Self.mapTimeline(timeline) }
        guard let ascendantID = ascendantID(forTimeline: timelineID),
              let runtime = ascendantRuntimes[ascendantID],
              let timeline = try await runtime.timelineManager.listTimelines().first(where: { $0.id == timelineID }) else {
            return TimelineStatus(timelineID: timelineID, title: "(unknown)", attachedWorkspaceIDs: [])
        }
        return Self.mapTimeline(timeline)
    }

    private func renameTimeline(_ request: TimelineUpdateRequest) async throws -> TimelineStatus {
        guard let ascendantID = ascendantID(forTimeline: request.timelineID),
              let runtime = ascendantRuntimes[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        try await runtime.timelineManager.updateTimelineTitle(id: request.timelineID, title: request.title)
        guard let timeline = try await runtime.timelineManager.listTimelines().first(where: { $0.id == request.timelineID }) else {
            throw NodeRuntimeError.missingTimeline(request.timelineID)
        }
        if runtimeTimelines[request.timelineID] != nil {
            runtimeTimelineRecords[request.timelineID] = timeline
        }
        timelineRecords[request.timelineID] = timeline
        if isRunning {
            lifecycle.readvertiseDiscoverableObject(object: GnosticTimelineObject(timeline: timeline))
        }
        return Self.mapTimeline(timeline)
    }

    private func attachableWorkspaces() async -> [WorkspaceListing] {
        await catalog.networkObjects()
            .filter { $0.objectType == GnosticObjectType.workspace && $0.workspace?.isAvailable == true }
            .map { WorkspaceListing(id: $0.objectID, name: $0.name, isAvailable: true) }
    }

    private func attachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool {
        guard let ascendantID = ascendantID(forTimeline: request.timelineID),
              let runtime = ascendantRuntimes[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        let service = DiscoveredWorkspaceAttachmentService(
            catalog: catalog,
            timelineManager: runtime.timelineManager,
            allowedTimelineIDs: [request.timelineID]
        )
        _ = try await service.attach(workspaceID: request.workspaceID, to: request.timelineID, approved: true)
        if let timeline = try await runtime.timelineManager.listTimelines().first(where: { $0.id == request.timelineID }) {
            timelineRecords[request.timelineID] = timeline
            lifecycle.readvertiseDiscoverableObject(object: GnosticTimelineObject(timeline: timeline))
        }
        return true
    }

    private func detachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool {
        guard let ascendantID = ascendantID(forTimeline: request.timelineID),
              let runtime = ascendantRuntimes[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(request.timelineID)
        }
        try await runtime.timelineManager.detachWorkspace(request.workspaceID, from: request.timelineID)
        if let timeline = try await runtime.timelineManager.listTimelines().first(where: { $0.id == request.timelineID }) {
            timelineRecords[request.timelineID] = timeline
            lifecycle.readvertiseDiscoverableObject(object: GnosticTimelineObject(timeline: timeline))
        }
        return true
    }

    private static func runTurn(
        kit: PositronicKit,
        timelineID: UUID,
        message: String,
        clientTurnID: String?,
        updates: AscendantTurnUpdateStore,
        additionalTools: [AnyTool]
    ) async throws -> String {
        let tools = await kit.timelineManager.enabledTools(for: timelineID) + additionalTools
        let stream = try await AscendantTurnPermissionContext.$current.withValue(
            clientTurnID.map { AscendantTurnPermissionContext.Value(timelineID: timelineID, clientTurnID: $0) }
        ) {
            try await kit.run(ChatRunRequest(timelineID: timelineID, message: message, tools: tools, maxTurns: 5))
        }
        var finalText = ""
        var failure: String?
        for try await event in stream {
            switch event {
            case .delta(.generation(let text)):
                if let clientTurnID { _ = await updates.append(timelineID: timelineID, clientTurnID: clientTurnID, kind: "assistant_text", text: text) }
            case .completion(.generationCompleted(let message, _)):
                finalText = message.content
            case .completion(.maxTurnsReached):
                failure = "The model exhausted its turn budget without a final answer."
            case .error(.error(let message, _)):
                failure = message
            case .error(.generationCancelled):
                throw CancellationError()
            default:
                break
            }
        }
        if let failure { throw NodeRuntimeError.turnFailed(failure) }
        return finalText.isEmpty ? "(empty reply)" : finalText
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
        guard workspaceReferences[workspaceID]?.uri.description == uri else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        try await installResolvedNetworkWorkspace(reference, workspaceID: workspaceID)
        return reference
    }

    public func networkAttachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await catalog.workspaceAttachmentStatus(id: workspaceID)
    }

    private func advertiseAll() {
        for runtime in ascendantRuntimes.values {
            advertise(GnosticAgentObject(agent: runtime.agent))
        }
        for timeline in timelineRecords.values { advertise(GnosticTimelineObject(timeline: timeline)) }
        for workspace in plan.workspaces {
            if let reference = workspaceReferences[workspace.id] {
                advertise(GnosticWorkspaceObject(workspace: reference))
            }
        }
    }

    private func respond(to request: DiscoverRequest) async throws {
        guard isRunning else { return }
        let types = request.snapshot.objectTypes
        for object in discoverableObjects() where types == nil || types?.contains(object.objectType) == true { try request.resolve(object: object) }
    }

    private func discoverableObjects() -> [CoatyObject] {
        var objects: [CoatyObject] = []
        for runtime in ascendantRuntimes.values {
            objects.append(GnosticAgentObject(agent: runtime.agent))
        }
        objects += timelineRecords.values.map(GnosticTimelineObject.init)
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
        let workspaceIDs = Set(plan.timelines.flatMap(\.attachments).filter { $0.scope == .network }.map(\.workspaceID))
        guard !workspaceIDs.isEmpty else { return }
        networkResolutionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.lifecycleState != .closed else { return }
                await self.subscription.discover(using: self.communication, timeout: .milliseconds(250))
                for workspaceID in workspaceIDs where self.workspaceReferences[workspaceID]?.tools.isEmpty == true {
                    _ = try? await self.resolveAvailableNetworkWorkspace(workspaceID)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @discardableResult
    private func resolveAvailableNetworkWorkspace(_ workspaceID: UUID) async throws -> WorkspaceReference? {
        guard let expectedURI = workspaceReferences[workspaceID]?.uri.description else { return nil }
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
        workspaceReferences[workspaceID] = reference
        let attachedTimelines = plan.timelines.filter {
            $0.attachments.contains { $0.workspaceID == workspaceID && $0.scope == .network }
        }
        for ascendantID in Set(attachedTimelines.compactMap(\.operatingAscendantID)) {
            guard let runtime = ascendantRuntimes[ascendantID] else { continue }
            try await runtime.kit.timelineManager.importWorkspace(reference)
            for timeline in attachedTimelines where timeline.operatingAscendantID == ascendantID {
                // PositronicKit intentionally permits attaching an existing ID;
                // doing so refreshes any already-hydrated tool registry with the
                // newly resolved remote Workspace implementation.
                try await runtime.kit.timelineManager.attachWorkspace(workspaceID, to: timeline.id)
            }
        }
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
        await turnCoordinator.cancelAll()
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

    private static func timeline(from configuration: NodeManifest.Timeline, agentID: UUID?) throws -> Timeline {
        Timeline(id: configuration.id, title: configuration.title, attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID), attachedAgentInstanceID: agentID, isPrivate: false)
    }

    private static func mapTimeline(_ timeline: Timeline) -> TimelineStatus {
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

private struct RuntimeWorkspaceFactory: WorkspaceFactory, Sendable {
    let local: [UUID: any Workspace]
    let remote: AxolotyWorkspaceFactory
    func create(from reference: WorkspaceReference) throws -> any Workspace {
        if let workspace = local[reference.id] { return workspace }
        return try remote.create(from: reference)
    }
}
