// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol
import PKContracts
import PositronicKit

/// Materializes a validated node manifest into one transport connection,
/// per-Ascendant runtime adapters, and complete canonical advertisements.
@MainActor
public final class NodeRuntime {
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
    private let localWorkspaces: [UUID: any WorkspaceProvider]
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
    public convenience init(
        plan: NodeLaunchPlan,
        adapters: NodeRuntimeAdapters = .default,
        turnLogURL: URL? = nil,
        timelineStoreDirectory: URL? = nil
    ) async throws {
        try await self.init(
            plan: plan,
            adapters: adapters,
            retirementPolicy: .live,
            turnLogURL: turnLogURL,
            timelineStoreDirectory: timelineStoreDirectory
        )
    }

    init(
        plan: NodeLaunchPlan,
        adapters: NodeRuntimeAdapters = .default,
        retirementPolicy: BackendRetirementPolicy,
        turnLogURL: URL? = nil,
        timelineStoreDirectory: URL? = nil
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
        if let turnLogURL {
            try await updates.enableDurability(at: turnLogURL)
        }
        turnUpdates = updates
        permissionCoordinator = AscendantPermissionCoordinator(updates: updates)
        turnCoordinator = AscendantTurnCoordinator(observers: adapters.terminalTurnObservers)

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
                retirementSupervisor: retirementSupervisor,
                runtimeTimelineDirectory: timelineStoreDirectory
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
            nodeID: plan.nodeID,
            ascendantIdentities: { [weak self] in self?.backendSupervisor.identities ?? [] },
            ascendantHealth: { [weak self] id in self?.backendSupervisor.health(for: id) ?? .unknown },
            workspaceReferences: { [weak self] in await self?.workspaceService.publicReferences() ?? [] },
            localWorkspaces: localWorkspaces,
            isAvailable: { [weak self] in self?.isRunning == true },
            turn: { [weak self] request in
                guard let self else { throw NodeRuntimeError.notRunning }
                return try await self.turnService.turn(request)
            },
            cancelTurn: { [weak self] request in
                guard let self else { return false }
                return await self.turnService.cancelTurn(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID
                )
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
            },
            diagnosticsNode: { [weak self] in
                guard let self else { throw NodeRuntimeError.notRunning }
                return await self.diagnosticsNodeSnapshot()
            },
            diagnosticsAscendant: { [weak self] id in
                guard let self else { throw NodeRuntimeError.notRunning }
                return try await self.diagnosticsAscendantSnapshot(id)
            },
            diagnosticsTimeline: { [weak self] id in
                guard let self else { throw NodeRuntimeError.notRunning }
                return try await self.diagnosticsTimelineSnapshot(id)
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
        // A cancelled caller must still drive the host to its disposed
        // boundary; the host owns the actual cleanup and reports completion.
        await withCancellationShield {
            await runtimeHost.shutdown()
        }
    }

    /// Returns the current health slot for an Ascendant's backend. Health is
    /// intentionally independent from the Gnostic-owned Timeline route.
    public func backendHealth(for ascendantID: UUID) async -> AscendantBackendHealth {
        backendSupervisor.health(for: ascendantID)
    }

    /// The runtime's bounded in-memory accounting, for soak resource tracking.
    ///
    /// - Returns: The retained Turn-ledger counts and their capacities. See
    ///   ``NodeRuntimeMetrics`` for why the ledger is the growth proxy.
    public func metrics() async -> NodeRuntimeMetrics {
        let ledger = await turnCoordinator.retainedStateCounts
        let capacity = await turnCoordinator.retainedCapacity
        let timelines = await turnCoordinator.retainedTimelineCount
        let inFlight = await turnCoordinator.inFlightCount
        return NodeRuntimeMetrics(
            inFlightTurns: inFlight,
            retainedTimelineCount: timelines,
            retainedIdentityCount: ledger.identities,
            retainedCompletedCount: ledger.completed,
            retainedTombstoneCount: ledger.tombstones,
            retainedCompletedBytes: ledger.completedBytes,
            identityCapacity: capacity.identities,
            completedCapacity: capacity.completed
        )
    }

    public func snapshot() async -> NodeRuntimeSnapshot {
        await registry.snapshot()
    }

    /// Returns an internal ownership view with static labels and no payloads.
    func effectSnapshots() async -> [RuntimeEffectSnapshot] {
        await runtimeHost.effectSnapshots()
    }

    /// Returns all host, transport, subscription, and Turn-observation
    /// ownership diagnostics for lifecycle verification.
    func allEffectSnapshots() async -> [RuntimeEffectSnapshot] {
        var snapshots = await runtimeHost.allEffectSnapshots()
        snapshots.append(await turnCoordinator.observationSnapshot())
        return snapshots
    }

    /// Returns the internal terminal-observation ownership view for lifecycle
    /// verification without exposing effect diagnostics as domain state.
    func observationSnapshot() async -> RuntimeEffectSnapshot {
        await turnCoordinator.observationSnapshot()
    }

    /// Returns a payload-free live snapshot for the whole Node.
    ///
    /// This is a read-only projection of canonical runtime state. It never
    /// carries Turn bodies, secrets, or effect details, and it never mutates
    /// the registry, the backend supervisor, or the Turn coordinator.
    func diagnosticsNodeSnapshot() async -> NodeDiagnostics {
        let ascendents = backendSupervisor.identities
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { identity in
                DiagnosticsAscendantSummary(
                    id: identity.id,
                    name: identity.name,
                    health: backendSupervisor.health(for: identity.id),
                    quarantined: backendSupervisor.isQuarantined(identity.id)
                )
            }
        let timelineIDs = await registry.listTimelines()
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        var timelines: [DiagnosticsTimelineSummary] = []
        for timelineID in timelineIDs {
            guard let record = await registry.timeline(id: timelineID) else { continue }
            timelines.append(DiagnosticsTimelineSummary(
                id: record.id,
                title: record.timeline.title,
                operatingAscendantID: record.operatorID
            ))
        }

        let workspaceIDs = await registry.snapshot().workspaceIDs
        let workspaces = await diagnosticsWorkspaceSummaries(ids: workspaceIDs)
        let retained = await turnCoordinator.retainedStateCounts
        let observation = await turnCoordinator.observationSnapshot()
        let turns = DiagnosticsTurnCounters(
            inFlight: await turnCoordinator.inFlightCount,
            completed: retained.completed,
            observationPending: await turnCoordinator.observationPendingCount,
            observationClosed: await turnCoordinator.observationIsClosed
        )
        let observer = DiagnosticsObserverDrain(
            liveObservations: observation.liveEffects.count,
            cleanupFailures: observation.cleanupFailures.count,
            retainedInFlight: retained.identities,
            retainedCompleted: retained.completed,
            retainedTombstones: retained.tombstones
        )
        return NodeDiagnostics(
            nodeID: plan.nodeID,
            ascendents: Array(ascendents.prefix(GnosticWirePayload.maximumListItems)),
            timelines: Array(timelines.prefix(GnosticWirePayload.maximumListItems)),
            workspaces: Array(workspaces.prefix(GnosticWirePayload.maximumListItems)),
            turns: turns,
            observer: observer
        )
    }

    /// Returns a payload-free live snapshot for one Ascendant.
    func diagnosticsAscendantSnapshot(_ ascendantID: UUID) async throws -> AscendantDiagnostics {
        guard let identity = backendSupervisor.identities.first(where: { $0.id == ascendantID }) else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        let privateTimelineID = identity.privateTimelineID
        let operated = await registry.listTimelines()
            .filter { $0.id == privateTimelineID || $0.attachedAscendantID == ascendantID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var timelines: [DiagnosticsTimelineSummary] = []
        for timeline in operated {
            timelines.append(DiagnosticsTimelineSummary(
                id: timeline.id,
                title: timeline.title,
                operatingAscendantID: await registry.operatorID(forTimeline: timeline.id)
            ))
        }
        return AscendantDiagnostics(
            ascendant: DiagnosticsAscendantSummary(
                id: identity.id,
                name: identity.name,
                health: backendSupervisor.health(for: identity.id),
                quarantined: backendSupervisor.isQuarantined(identity.id)
            ),
            description: identity.description,
            backendKind: identity.capabilities.backendKind,
            backendVersion: identity.capabilities.backendVersion,
            capabilities: identity.capabilities.interoperability.sorted(),
            privateTimelineID: identity.privateTimelineID,
            primaryWorkspaceID: identity.primaryWorkspaceID,
            timelines: Array(timelines.prefix(GnosticWirePayload.maximumListItems))
        )
    }

    /// Returns a payload-free live snapshot for one Timeline.
    func diagnosticsTimelineSnapshot(_ timelineID: UUID) async throws -> TimelineDiagnostics {
        guard let record = await registry.timeline(id: timelineID) else {
            throw NodeRuntimeError.missingTimeline(timelineID)
        }
        let workspaces = await diagnosticsWorkspaceSummaries(ids: record.timeline.attachedWorkspaceIDs)
        return TimelineDiagnostics(
            timeline: DiagnosticsTimelineSummary(
                id: record.id,
                title: record.timeline.title,
                operatingAscendantID: record.operatorID
            ),
            workspaces: Array(workspaces.prefix(GnosticWirePayload.maximumListItems))
        )
    }

    private func diagnosticsWorkspaceSummaries(ids: [UUID]) async -> [DiagnosticsWorkspaceSummary] {
        var summaries: [DiagnosticsWorkspaceSummary] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = await registry.workspace(id: id) else { continue }
            summaries.append(DiagnosticsWorkspaceSummary(
                id: record.id,
                uri: record.uri,
                status: GnosticWorkspaceEffectiveStatus(rawValue: record.status.rawValue) ?? .unsupported
            ))
        }
        return summaries
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
        let status = await registry.effectiveWorkspaceStatus(id: id)
            .map { GnosticWorkspaceEffectiveStatus(rawValue: $0.rawValue) ?? .unsupported }
        return WorkspaceReferenceProjection.networkReference(from: reference, effectiveStatus: status)
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
