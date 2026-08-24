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
    @available(*, deprecated, message: "Use EchoWorkspace.toolID instead.")
    public nonisolated static let echoToolID = EchoWorkspace.toolID

    public let plan: NodeLaunchPlan
    public var launchPlan: NodeLaunchPlan { plan }
    public let host: String
    public let port: Int
    public let namespace: String
    private let runtimeHost: NodeRuntimeHost
    public var isRunning: Bool { runtimeHost.isRunning }
    /// Canonical domain state. Adapter persistence and network objects are
    /// projections of the records accepted by this actor.
    private let registry: NodeRegistry

    private let adapters: NodeRuntimeAdapters
    private let initialWorkspaceReferences: [UUID: WorkspaceReference]
    private let localWorkspaces: [UUID: any Workspace]
    private let backendSupervisor: AscendantBackendSupervisor
    private let turnCoordinator: AscendantTurnCoordinator
    private let turnUpdates: AscendantTurnUpdateStore
    private let permissionCoordinator: AscendantPermissionCoordinator
    private let projectionRelay = NodeProjectionRelay()
    private lazy var workspaceDiscovery = AxolotyWorkspaceDiscovery(
        catalog: runtimeHost.resources.catalog,
        subscription: runtimeHost.resources.subscription,
        communication: runtimeHost.resources.communication
    )
    private lazy var workspaceService = WorkspaceService(
        plan: plan,
        registry: registry,
        discovery: workspaceDiscovery,
        localWorkspaces: localWorkspaces,
        references: initialWorkspaceReferences,
        backendWorkspaceService: runtimeHost.resources.backendWorkspaceService,
        backendProvider: backendSupervisor,
        readvertiseTimeline: { [projectionRelay] timeline in
            projectionRelay.projectTimeline(timeline, replacing: true)
        }
    )
    private lazy var turnService = TurnService(
        registry: registry,
        coordinator: turnCoordinator,
        updates: turnUpdates,
        backendProvider: backendSupervisor
    )
    private lazy var timelineService = TimelineService(
        ascendantIDs: Set(plan.ascendants.map(\.id)),
        registry: registry,
        backendProvider: backendSupervisor,
        advertise: { [projectionRelay] timeline, replacing in
            projectionRelay.projectTimeline(timeline, replacing: replacing)
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
        let retirementSupervisor = BackendRetirementSupervisor(policy: retirementPolicy)
        let updates = AscendantTurnUpdateStore()
        turnUpdates = updates
        permissionCoordinator = AscendantPermissionCoordinator(updates: updates)
        turnCoordinator = AscendantTurnCoordinator()

        let products = try await NodeAssembly.materializeWorkspaces(plan, adapters: adapters)
        initialWorkspaceReferences = products.references
        localWorkspaces = products.workspaces
        let infrastructure = try NodeAssembly.resolveInfrastructure(for: plan, products: products)
        let runtimeHost = NodeRuntimeHost(
            lifecycleCoordinator: coordinator,
            resources: infrastructure,
            adapters: adapters,
            turnUpdates: updates,
            permissionCoordinator: permissionCoordinator,
            turnCoordinator: turnCoordinator,
            projectionRelay: projectionRelay
        )
        self.runtimeHost = runtimeHost

        do {
            let products = try await NodeAssembly.buildBackends(
                for: plan,
                adapters: adapters,
                infrastructure: infrastructure,
                permissionCoordinator: permissionCoordinator,
                lifetime: runtimeHost.lifetime,
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
            infrastructure.container.shutdown()
            throw error
        }

        let wiring = NodeRuntimeHost.TransportWiring(
            ascendantIdentities: { [weak self] in self?.backendSupervisor.identities ?? [] },
            ascendantHealth: { [weak self] id in self?.backendSupervisor.health(for: id) ?? .unknown },
            workspaceReferences: { [initialWorkspaceReferences, plan] in
                initialWorkspaceReferences.values.filter { reference in
                    plan.workspaces.contains { $0.id == reference.id }
                }.map(WorkspaceReferenceProjection.networkReference)
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
        runtimeHost.configure(
            registry: registry,
            backendSupervisor: backendSupervisor,
            wiring: wiring,
            refreshUnresolved: { [weak self] in await self?.workspaceService.refreshUnresolved() }
        )
    }

    public convenience init(launchPlan: NodeLaunchPlan, adapters: NodeRuntimeAdapters = .default) async throws {
        try await self.init(plan: launchPlan, adapters: adapters)
    }

    public func start() async throws {
        try await runtimeHost.start()
    }

    public func shutdown() async {
        await runtimeHost.shutdown()
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

    public func workspaceReference(id: UUID) async -> GnosticWorkspaceReference? {
        guard let reference = await workspaceService.reference(id: id) else { return nil }
        return WorkspaceReferenceProjection.networkReference(from: reference)
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
    public func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> GnosticWorkspaceReference {
        let reference = try await workspaceService.resolveNetworkWorkspace(workspaceID: workspaceID, timeout: timeout)
        return WorkspaceReferenceProjection.networkReference(from: reference)
    }

    public func networkAttachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await workspaceService.networkAttachmentStatus(workspaceID: workspaceID)
    }

}
