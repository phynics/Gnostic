// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

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
    private let initialWorkspaceReferences: [UUID: WorkspaceReference]
    private let localWorkspaces: [UUID: any Workspace]
    private var lifecycleState: LifecycleState = .stopped
    private let turnCoordinator: AscendantTurnCoordinator
    private let turnUpdates: AscendantTurnUpdateStore
    private let permissionCoordinator: AscendantPermissionCoordinator
    private let projectionRelay = NodeProjectionRelay()
    private lazy var workspaceDiscovery = AxolotyWorkspaceDiscovery(
        catalog: catalog,
        subscription: subscription,
        communication: communication
    )
    private lazy var workspaceService = WorkspaceService(
        plan: plan,
        registry: registry,
        discovery: workspaceDiscovery,
        localWorkspaces: localWorkspaces,
        references: initialWorkspaceReferences,
        isRunning: { [weak self] in self?.isRunning == true },
        adapter: { [weak self] in self?.ascendantAdapters[$0] },
        readvertiseTimeline: { [projectionRelay] timeline in
            projectionRelay.projectTimeline(timeline, replacing: true)
        }
    )
    private lazy var chatService = ChatTurnService(
        registry: registry,
        coordinator: turnCoordinator,
        updates: turnUpdates,
        isRunning: { [weak self] in self?.isRunning == true },
        adapter: { [weak self] in self?.ascendantAdapters[$0] }
    )
    private lazy var timelineService = TimelineService(
        ascendantIDs: Set(plan.ascendants.map(\.id)),
        registry: registry,
        isClosed: { [weak self] in self?.lifecycleState == .closed },
        adapter: { [weak self] in self?.ascendantAdapters[$0] },
        advertise: { [projectionRelay] timeline, replacing in
            projectionRelay.projectTimeline(timeline, replacing: replacing)
        }
    )
    private lazy var transport = NodeTransport(
        communication: communication,
        lifecycle: lifecycle,
        registry: registry,
        ascendantIdentities: { [weak self] in self?.ascendantAdapters.values.map(\.identity) ?? [] },
        workspaceReferences: { [initialWorkspaceReferences, plan] in
            initialWorkspaceReferences.values.filter { reference in
                plan.workspaces.contains { $0.id == reference.id }
            }
        },
        localWorkspaces: localWorkspaces,
        isAvailable: { [weak self] in self?.isRunning == true },
        chat: { [weak self] request in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.chatService.chat(request)
        },
        timelineStatus: { [weak self] id in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.timelineService.status(for: id)
        },
        selectAscendant: { [weak self] id in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try self.timelineService.selectAscendant(requested: id)
        },
        createTimeline: { [weak self] title, ascendantID in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.timelineService.create(title: title, ascendantID: ascendantID)
        },
        listTimelines: { [weak self] in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.timelineService.list()
        },
        renameTimeline: { [weak self] request in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.timelineService.rename(request)
        },
        listWorkspaces: { [weak self] in await self?.workspaceService.listAttachable() ?? [] },
        attachWorkspace: { [weak self] request in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.workspaceService.attach(request)
        },
        detachWorkspace: { [weak self] request in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.workspaceService.detach(request)
        }
    )
    private var turnUpdatePublishTask: Task<Void, Never>?
    private var networkResolutionTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var shutdownTask: Task<Void, Never>?

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
        initialWorkspaceReferences = references
        localWorkspaces = workspaces
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
            projectionRelay.bind(transport)
            try await container.startAndWaitUntilReady()
            try requireActiveStart()
            try adapters.lifecycle.afterConnection()
            try await subscription.start()
            try requireActiveStart()
            startNetworkResolution()
            try await transport.registerOperations(
                turnUpdates: turnUpdates,
                permissionCoordinator: permissionCoordinator
            )

            let events = await turnUpdates.events()
            turnUpdatePublishTask = Task { [communication] in
                for await event in events {
                    guard let channel = try? AgentChatProvider.updateEvent(event) else { continue }
                    communication.publishChannel(channel)
                }
            }

            try requireActiveStart()
            try adapters.lifecycle.afterRegistration()
            try await adapters.lifecycle.beforeDiscoverResponder()
            await transport.registerDiscoverResponder()
            try await adapters.lifecycle.afterDiscoverResponder()
            try requireActiveStart()
            try adapters.lifecycle.beforeAdvertisement()
            lifecycleState = .running
            await transport.advertiseAll()
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

    public func selectAscendant(requested ascendantID: UUID?) async throws -> UUID {
        try timelineService.selectAscendant(requested: ascendantID)
    }

    public func workspaceReference(id: UUID) async -> WorkspaceReference? {
        await workspaceService.reference(id: id)
    }

    public func executeWorkspaceTool(workspaceID: UUID, toolID: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        try await workspaceService.executeLocalTool(workspaceID: workspaceID, toolID: toolID, arguments: arguments)
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
        try await chatService.chat(request)
    }

    /// Creates a timeline in the selected Ascendant's in-memory runtime. It
    /// is intentionally absent from the launch plan and therefore process-only.
    @discardableResult
    public func createTimeline(title: String, ascendantID: UUID) async throws -> TimelineStatus {
        try await timelineService.create(title: title, ascendantID: ascendantID)
    }

    public func listTimelines() async throws -> [TimelineStatus] {
        try await timelineService.list()
    }

    public func timelineStatus(for timelineID: UUID) async throws -> TimelineStatus {
        try await timelineService.status(for: timelineID)
    }

    public func renameTimeline(_ request: TimelineUpdateRequest) async throws -> TimelineStatus {
        try await timelineService.rename(request)
    }

    public func attachableWorkspaces() async -> [WorkspaceListing] {
        await workspaceService.listAttachable()
    }

    public func attachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool {
        try await workspaceService.attach(request)
    }

    public func detachWorkspace(_ request: WorkspaceOpsRequest) async throws -> Bool {
        try await workspaceService.detach(request)
    }

    /// Discovers and imports a network Workspace only when a caller needs it.
    /// Construction and startup never resolve network attachments.
    @discardableResult
    public func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> WorkspaceReference {
        try await workspaceService.resolveNetworkWorkspace(workspaceID: workspaceID, timeout: timeout)
    }

    public func networkAttachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await workspaceService.networkAttachmentStatus(workspaceID: workspaceID)
    }

    private func startNetworkResolution() {
        networkResolutionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.lifecycleState != .closed else { return }
                await self.workspaceService.refreshUnresolved()
                try? await Task.sleep(for: .milliseconds(250))
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
        await transport.cancel()
        let publishTask = turnUpdatePublishTask
        let resolutionTask = networkResolutionTask
        publishTask?.cancel(); turnUpdatePublishTask = nil
        resolutionTask?.cancel(); networkResolutionTask = nil
        for adapter in ascendantAdapters.values { await adapter.cancelAll() }
        await turnCoordinator.cancelAll()
        for adapter in ascendantAdapters.values { await adapter.shutdown() }
        await permissionCoordinator.denyAll(reason: "connection_lost")
        await publishTask?.value
        await resolutionTask?.value
        subscription.stop()
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
