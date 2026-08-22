// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Materializes a validated node manifest into one transport connection,
/// per-Ascendant runtime adapters, and complete canonical advertisements.
@MainActor
public final class NodeRuntime {
    /// Compatibility alias for the echo adapter's public tool identifier.
    public nonisolated static let echoToolID = EchoWorkspace.toolID

    public let plan: NodeLaunchPlan
    public var launchPlan: NodeLaunchPlan { plan }
    public let host: String
    public let port: Int
    public let namespace: String
    private let lifecycleCoordinator: RuntimeLifecycleCoordinator
    private let lifetime: NodeRuntimeLifetime
    public var isRunning: Bool { lifetime.isRunning }
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
    private let backendWorkspaceService: GnosticWorkspaceBackendService
    private let backendSupervisor: AscendantBackendSupervisor
    private let turnCoordinator: AscendantTurnCoordinator
    private let turnUpdates: AscendantTurnUpdateStore
    private let permissionCoordinator: AscendantPermissionCoordinator
    private let projectionRelay = NodeProjectionRelay()
    private lazy var backendAccess = BackendSessionAccess(
        isRunning: { [weak self] in self?.isRunning == true },
        isClosed: { [weak self] in self?.lifetime.state == .closed },
        lifecycleGeneration: { [weak self] in self?.lifetime.generation ?? 0 },
        session: { [weak self] ascendantID in self?.backendSupervisor.session(for: ascendantID) },
        isCurrent: { [weak self] ascendantID, backend, generation in
            self?.backendSupervisor.isCurrentBackend(ascendantID, backend: backend, generation: generation) == true
        },
        lease: { [weak self] ascendantID, backend in
            self?.backendSupervisor.lease(for: ascendantID, backend: backend)
        },
        lifecycleFailure: { [weak self] ascendantID, backend, failure in
            await self?.backendSupervisor.markLifecycleFailure(ascendantID, backend: backend, failure: failure)
        }
    )
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
        backendWorkspaceService: backendWorkspaceService,
        access: backendAccess,
        readvertiseTimeline: { [projectionRelay] timeline in
            projectionRelay.projectTimeline(timeline, replacing: true)
        }
    )
    private lazy var turnService = TurnService(
        registry: registry,
        coordinator: turnCoordinator,
        updates: turnUpdates,
        access: backendAccess,
        backend: { [weak self] ascendantID in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.backendSupervisor.backendForTurn(ascendantID)
        }
    )
    private lazy var timelineService = TimelineService(
        ascendantIDs: Set(plan.ascendants.map(\.id)),
        registry: registry,
        access: backendAccess,
        advertise: { [projectionRelay] timeline, replacing in
            projectionRelay.projectTimeline(timeline, replacing: replacing)
        }
    )
    private lazy var transport = NodeTransport(
        communication: communication,
        lifecycle: lifecycle,
        registry: registry,
        ascendantIdentities: { [weak self] in self?.backendSupervisor.identities ?? [] },
        ascendantHealth: { [weak self] id in self?.backendSupervisor.health(for: id) ?? .unknown },
        workspaceReferences: { [initialWorkspaceReferences, plan] in
            initialWorkspaceReferences.values.filter { reference in
                plan.workspaces.contains { $0.id == reference.id }
            }
        },
        localWorkspaces: localWorkspaces,
        isAvailable: { [weak self] in self?.isRunning == true },
        turn: { [weak self] request in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.turnService.turn(request)
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
    public convenience init(plan: NodeLaunchPlan, adapters: NodeRuntimeAdapters = .default) async throws {
        try await self.init(plan: plan, adapters: adapters, retirementPolicy: .live)
    }

    init(
        plan: NodeLaunchPlan,
        adapters: NodeRuntimeAdapters = .default,
        retirementPolicy: BackendRetirementPolicy
    ) async throws {
        try NodeAssembly.validate(plan, adapters: adapters)
        self.plan = plan
        host = plan.broker.host
        port = plan.broker.port
        namespace = plan.broker.namespace
        self.adapters = adapters
        let coordinator = RuntimeLifecycleCoordinator()
        lifecycleCoordinator = coordinator
        lifetime = coordinator.lifetime
        let retirementSupervisor = BackendRetirementSupervisor(policy: retirementPolicy)
        let updates = AscendantTurnUpdateStore()
        turnUpdates = updates
        permissionCoordinator = AscendantPermissionCoordinator(updates: updates)
        turnCoordinator = AscendantTurnCoordinator()

        let products = try await NodeAssembly.materializeWorkspaces(plan, adapters: adapters)
        initialWorkspaceReferences = products.references
        localWorkspaces = products.workspaces
        let infrastructure = try NodeAssembly.resolveInfrastructure(for: plan, products: products)
        container = infrastructure.container
        communication = infrastructure.communication
        lifecycle = infrastructure.lifecycle
        catalog = infrastructure.catalog
        subscription = infrastructure.subscription
        backendWorkspaceService = infrastructure.backendWorkspaceService

        do {
            let products = try await NodeAssembly.buildBackends(
                for: plan,
                adapters: adapters,
                infrastructure: infrastructure,
                permissionCoordinator: permissionCoordinator,
                lifetime: lifetime,
                projectionRelay: projectionRelay,
                retirementSupervisor: retirementSupervisor
            )
            registry = products.registry
            backendSupervisor = products.supervisor
            for attachment in products.attachmentCapabilities {
                attachment.capability.bind { [weak self] workspaceID, timelineID in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    try await self.workspaceService.attachFromBackend(
                        workspaceID: workspaceID,
                        timelineID: timelineID,
                        ascendantID: attachment.ascendantID,
                        backendLease: attachment.lease
                    )
                }
            }
            backendSupervisor.bind(
                attachWorkspace: { [weak self] workspaceID, timelineID, ascendantID, backendLease in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    try await self.workspaceService.attachFromBackend(
                        workspaceID: workspaceID,
                        timelineID: timelineID,
                        ascendantID: ascendantID,
                        backendLease: backendLease
                    )
                }
            )
        } catch {
            container.shutdown()
            throw error
        }
    }

    public convenience init(launchPlan: NodeLaunchPlan, adapters: NodeRuntimeAdapters = .default) async throws {
        try await self.init(plan: launchPlan, adapters: adapters)
    }

    public func start() async throws {
        try await lifecycleCoordinator.start(
            prepare: { [registry] generation in
                await registry.setLifecycleGeneration(generation)
            },
            operation: { [weak self] in
                guard let self else { throw NodeRuntimeError.notRunning }
                try await self.performStart()
            }
        )
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
            lifetime.turnUpdatePublishTask = Task { [communication] in
                for await event in events {
                    guard let channel = try? AscendantTurnProvider.updateEvent(event) else { continue }
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
            lifetime.markRunning()
            await transport.advertiseAll()
            try await adapters.lifecycle.afterAdvertisement()
            try requireActiveRunningStart()
        } catch {
            await lifecycleCoordinator.rollback(close: true) { [weak self] cleanup in
                await self?.performCleanup(cleanup)
            }
            throw error
        }
    }

    public func shutdown() async {
        await lifecycleCoordinator.shutdown { [weak self] cleanup in
            await self?.performCleanup(cleanup)
        }
    }

    /// Returns the current health slot for an Ascendant's backend. Health is
    /// intentionally independent from the Gnostic-owned Timeline route.
    public func backendHealth(for ascendantID: UUID) async -> AscendantBackendHealth {
        backendSupervisor.health(for: ascendantID)
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
        try await backendSupervisor.enabledToolIDs(for: timelineID)
    }

    /// Runs one Turn against the adapter selected by the
    /// addressed timeline. Unoperated timelines remain observable but cannot
    /// accidentally fall through to an arbitrary Ascendant.
    public func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try await turnService.turn(request)
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
        lifetime.networkResolutionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.lifetime.state != .closed else { return }
                await self.workspaceService.refreshUnresolved()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func requireActiveStart() throws {
        try lifecycleCoordinator.requireActiveStart()
    }

    private func requireActiveRunningStart() throws {
        try lifecycleCoordinator.requireActiveRunningStart()
    }

    private func performCleanup(_ cleanup: NodeRuntimeLifetime.CleanupTasks) async {
        await registry.fenceBackendLeases(at: lifetime.generation)
        await permissionCoordinator.denyAll(reason: "connection_lost")
        transport.cancel()
        backendSupervisor.cancelReconstructions()
        await turnCoordinator.cancelAll(waitForCompletion: false)
        await turnUpdates.finish()
        await backendSupervisor.retireAll(stage: .runtimeShutdown)
        cleanup.publishTask?.cancel()
        await cleanup.publishTask?.value
        cleanup.resolutionTask?.cancel()
        await cleanup.resolutionTask?.value
        subscription.stop()
        container.shutdown()
    }

}
