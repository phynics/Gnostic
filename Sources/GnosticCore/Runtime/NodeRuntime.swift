// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Materializes a validated node manifest into one transport connection,
/// per-Ascendant runtime adapters, and complete canonical advertisements.
@MainActor
public final class NodeRuntime {
    private struct BackendSpec {
        let ascendant: NodeManifest.Ascendant
        let configuration: AscendantBackendConfiguration
    }

    private struct BackendReconstructionFailure: Error, LocalizedError, Sendable {
        let detail: String

        var errorDescription: String? { "Backend reconstruction failed: \(detail)" }
    }

    public nonisolated static let echoToolID = "workspace_echo"

    public let plan: NodeLaunchPlan
    public var launchPlan: NodeLaunchPlan { plan }
    public let host: String
    public let port: Int
    public let namespace: String
    public var isRunning: Bool { lifetime.isRunning }
    private let lifetime = NodeRuntimeLifetime()
    private var ascendantAdapters: [UUID: any AscendantBackend]
    private let backendIdentities: [AscendantBackendIdentity]
    private var backendSpecs: [UUID: BackendSpec] = [:]
    private var backendHealthByID: [UUID: AscendantBackendHealth] = [:]
    private var backendLeases: [UUID: UUID] = [:]
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
    private let backendRetirementSupervisor: BackendRetirementSupervisor
    private var backendWorkspaceCapability: BackendWorkspaceDiscoveryCapability?
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
        backendWorkspaceService: backendWorkspaceService,
        isRunning: { [weak self] in self?.isRunning == true },
        lifecycleGeneration: { [weak self] in self?.lifetime.generation ?? 0 },
        isCurrentBackend: { [weak self] ascendantID, backend, generation in
            self?.isCurrentBackend(ascendantID, backend: backend, generation: generation) == true
        },
        backendLease: { [weak self] ascendantID, backend in
            self?.lease(for: ascendantID, backend: backend)
        },
        adapter: { [weak self] ascendantID in
            guard let self, self.backendHealthByID[ascendantID] == .healthy else { return nil }
            return self.ascendantAdapters[ascendantID]
        },
        lifecycleFailure: { [weak self] ascendantID, backend, failure in
            await self?.markBackendLifecycleFailure(ascendantID, backend: backend, failure: failure)
        },
        readvertiseTimeline: { [projectionRelay] timeline in
            projectionRelay.projectTimeline(timeline, replacing: true)
        }
    )
    private lazy var turnService = TurnService(
        registry: registry,
        coordinator: turnCoordinator,
        updates: turnUpdates,
        isRunning: { [weak self] in self?.isRunning == true },
        backend: { [weak self] ascendantID in
            guard let self else { throw NodeRuntimeError.notRunning }
            return try await self.backendForTurn(ascendantID)
        },
        lifecycleGeneration: { [weak self] in self?.lifetime.generation ?? 0 },
        lifecycleFailure: { [weak self] ascendantID, backend, failure in
            await self?.markBackendLifecycleFailure(ascendantID, backend: backend, failure: failure)
        }
    )
    private lazy var timelineService = TimelineService(
        ascendantIDs: Set(plan.ascendants.map(\.id)),
        registry: registry,
        isClosed: { [weak self] in self?.lifetime.state == .closed },
        lifecycleGeneration: { [weak self] in self?.lifetime.generation ?? 0 },
        isCurrentBackend: { [weak self] ascendantID, backend, generation in
            self?.isCurrentBackend(ascendantID, backend: backend, generation: generation) == true
        },
        backendLease: { [weak self] ascendantID, backend in
            self?.lease(for: ascendantID, backend: backend)
        },
        adapter: { [weak self] ascendantID in
            guard let self, self.backendHealthByID[ascendantID] == .healthy else { return nil }
            return self.ascendantAdapters[ascendantID]
        },
        lifecycleFailure: { [weak self] ascendantID, backend, failure in
            await self?.markBackendLifecycleFailure(ascendantID, backend: backend, failure: failure)
        },
        advertise: { [projectionRelay] timeline, replacing in
            projectionRelay.projectTimeline(timeline, replacing: replacing)
        }
    )
    private lazy var transport = NodeTransport(
        communication: communication,
        lifecycle: lifecycle,
        registry: registry,
        ascendantIdentities: { [weak self] in self?.backendIdentities ?? [] },
        ascendantHealth: { [weak self] id in self?.backendHealthByID[id] ?? .unknown },
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
        try NodeRuntime.validate(plan: plan)
        self.plan = plan
        host = plan.broker.host
        port = plan.broker.port
        namespace = plan.broker.namespace
        self.adapters = adapters
        backendRetirementSupervisor = BackendRetirementSupervisor(policy: retirementPolicy)
        ascendantAdapters = [:]
        let updates = AscendantTurnUpdateStore()
        turnUpdates = updates
        permissionCoordinator = AscendantPermissionCoordinator(updates: updates)
        turnCoordinator = AscendantTurnCoordinator()

        try adapters.ascendants.validate(kinds: plan.ascendants.map { plan.backend(for: $0.id)?.kind ?? $0.kind })
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
                objectTypes: [GnosticAscendantObject.self, GnosticTimelineObject.self, GnosticWorkspaceObject.self]
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
        backendWorkspaceService = GnosticWorkspaceBackendService(
            localWorkspaces: workspaces,
            references: references,
            catalog: objectCatalog,
            communication: communicationManager
        )

        do {
            var operatedTimelines: [AscendantRuntimeTimeline] = []
            var identities: [AscendantBackendIdentity] = []
            let backendDiscovery = AxolotyWorkspaceDiscovery(
                catalog: objectCatalog,
                subscription: subscription,
                communication: communicationManager
            )
            let workspaceCapability = BackendWorkspaceDiscoveryCapability(discovery: backendDiscovery)
            backendWorkspaceCapability = workspaceCapability
            var specs: [UUID: BackendSpec] = [:]
            var leases: [UUID: UUID] = [:]
            var attachmentCapabilities: [(ascendantID: UUID, lease: UUID, capability: BackendWorkspaceAttachmentCapability)] = []
            for ascendant in plan.ascendants {
                guard let backend = plan.backend(for: ascendant.id) else { throw NodeRuntimeError.unsupportedAscendantKind(ascendant.kind) }
                let timelineConfigurations = plan.timelines.filter { $0.operatingAscendantID == ascendant.id }
                let lease = UUID.makeVersion4()
                let attachmentCapability = BackendWorkspaceAttachmentCapability()
                specs[ascendant.id] = BackendSpec(
                    ascendant: ascendant,
                    configuration: backend
                )
                leases[ascendant.id] = lease
                attachmentCapabilities.append((ascendant.id, lease, attachmentCapability))
                let backendServices = AscendantBackendServices(
                    workspace: backendWorkspaceService,
                    permission: permissionCoordinator,
                    optionalCapabilities: [workspaceCapability, attachmentCapability]
                )
                let backendInstance = try await adapters.ascendants.makeBackend(for: ascendant, backend: backend, services: backendServices, timelines: timelineConfigurations)
                do {
                    try backendInstance.validateConfiguration()
                } catch {
                    await backendRetirementSupervisor.retire(
                        [(id: backendInstance.identity.id, backend: backendInstance)],
                        stage: .initializationRollback
                    )
                    throw error
                }
                ascendantAdapters[ascendant.id] = backendInstance
                backendHealthByID[ascendant.id] = .healthy
                identities.append(backendInstance.identity)
                operatedTimelines += try await backendInstance.operatedTimelines()
            }
            registry = try NodeRegistry(
                plan: plan,
                operatedTimelines: operatedTimelines,
                backendLeases: leases
            )
            backendLeases = leases
            backendSpecs = specs
            backendIdentities = identities
            for attachment in attachmentCapabilities {
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
        } catch {
            let adapters = ascendantAdapters.map { (id: $0.key, backend: $0.value) }
            ascendantAdapters.removeAll()
            await backendRetirementSupervisor.retire(adapters, stage: .initializationRollback)
            container.shutdown()
            throw error
        }
    }

    public convenience init(launchPlan: NodeLaunchPlan, adapters: NodeRuntimeAdapters = .default) async throws {
        try await self.init(plan: launchPlan, adapters: adapters)
    }

    public func start() async throws {
        guard try lifetime.beginStart() else { return }
        let generation = lifetime.generation
        await registry.setLifecycleGeneration(generation)
        guard lifetime.state == .starting, lifetime.generation == generation else {
            throw NodeRuntimeError.notRunning
        }

        let startup = Task { @MainActor [weak self] in
            guard let self else { throw NodeRuntimeError.notRunning }
            try await self.performStart()
        }
        lifetime.startupTask = startup
        do {
            try await startup.value
            lifetime.startupTask = nil
        } catch {
            lifetime.startupTask = nil
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
            await rollbackStart(close: true)
            throw error
        }
    }

    public func shutdown() async {
        if let shutdownTask = lifetime.shutdownTask {
            await shutdownTask.value
            return
        }
        guard let shutdownState = lifetime.beginShutdown() else {
            if let cleanupTask = lifetime.cleanupTask {
                await cleanupTask.value
            }
            return
        }
        let startup = shutdownState.startupTask
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
        lifetime.shutdownTask = cleanup
        await cleanup.value
        lifetime.shutdownTask = nil
    }

    /// Returns the current health slot for an Ascendant's backend. Health is
    /// intentionally independent from the Gnostic-owned Timeline route.
    public func backendHealth(for ascendantID: UUID) async -> AscendantBackendHealth {
        backendHealthByID[ascendantID] ?? .unknown
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
              backendHealthByID[ascendantID] == .healthy,
              let backend = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(timelineID)
        }
        guard let adapter = backend as? any AscendantBackendWorkspaceCapability else { return [] }
        return await adapter.enabledToolIDs(for: timelineID)
    }

    /// Runs one Turn against the adapter selected by the
    /// addressed timeline. Unoperated timelines remain observable but cannot
    /// accidentally fall through to an arbitrary Ascendant.
    public func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try await turnService.turn(request)
    }

    private func backendForTurn(_ ascendantID: UUID) async throws -> any AscendantBackend {
        guard lifetime.state == .running else { throw NodeRuntimeError.notRunning }
        guard backendSpecs[ascendantID] != nil else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        if backendHealthByID[ascendantID] == .healthy, let backend = ascendantAdapters[ascendantID] {
            return backend
        }
        return try await reconstructBackend(for: ascendantID)
    }

    private func isCurrentBackend(
        _ ascendantID: UUID,
        backend: any AscendantBackend,
        generation: UInt64
    ) -> Bool {
        guard lifetime.state != .closed,
              lifetime.generation == generation,
              let currentBackend = ascendantAdapters[ascendantID] else { return false }
        return (currentBackend as AnyObject) === (backend as AnyObject)
    }

    private func lease(
        for ascendantID: UUID,
        backend: any AscendantBackend
    ) -> UUID? {
        guard let currentBackend = ascendantAdapters[ascendantID],
              (currentBackend as AnyObject) === (backend as AnyObject) else { return nil }
        return backendLeases[ascendantID]
    }

    private func markBackendLifecycleFailure(
        _ ascendantID: UUID,
        backend failedBackend: any AscendantBackend,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard backendSpecs[ascendantID] != nil,
              let currentBackend = ascendantAdapters[ascendantID],
              (currentBackend as AnyObject) === (failedBackend as AnyObject) else { return }
        backendHealthByID[ascendantID] = .failed
        readvertiseAscendant(ascendantID, health: .failed)
        // A failed backend must not receive another operation while its
        // replacement is being built. Its Gnostic identity remains routed by
        // the registry and is never removed here.
        backendLeases.removeValue(forKey: ascendantID)
        await registry.invalidateBackendLease(for: ascendantID)
        if let backend = ascendantAdapters.removeValue(forKey: ascendantID) {
            await backendRetirementSupervisor.retire(
                [(id: ascendantID, backend: backend)],
                stage: .quarantine
            )
        }
        _ = failure
    }

    private func reconstructBackend(for ascendantID: UUID) async throws -> any AscendantBackend {
        if let task = lifetime.reconstructionTasks[ascendantID] {
            return try await task.value
        }
        guard let spec = backendSpecs[ascendantID] else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }

        let generation = lifetime.generation
        backendHealthByID[ascendantID] = .unknown
        readvertiseAscendant(ascendantID, health: .unknown)
        let task = Task { @MainActor [weak self] () throws -> any AscendantBackend in
            guard let self else { throw NodeRuntimeError.notRunning }
            var candidate: (any AscendantBackend)?
            do {
                guard self.isCurrentReconstructionGeneration(generation) else {
                    throw NodeRuntimeError.notRunning
                }
                let state = await self.registry.backendReconstructionState(for: ascendantID)
                let lease = UUID.makeVersion4()
                let attachmentCapability = BackendWorkspaceAttachmentCapability { [weak self] workspaceID, timelineID in
                    guard let self else { throw NodeRuntimeError.notRunning }
                    try await self.workspaceService.attachFromBackend(
                        workspaceID: workspaceID,
                        timelineID: timelineID,
                        ascendantID: ascendantID,
                        backendLease: lease
                    )
                }
                var optionalCapabilities: [any AscendantBackendOptionalCapability] = [attachmentCapability]
                if let workspaceCapability = self.backendWorkspaceCapability {
                    optionalCapabilities.insert(workspaceCapability, at: 0)
                }
                let services = AscendantBackendServices(
                    workspace: self.backendWorkspaceService,
                    permission: self.permissionCoordinator,
                    optionalCapabilities: optionalCapabilities
                )
                let created = try await self.adapters.ascendants.makeBackend(
                    for: spec.ascendant,
                    backend: spec.configuration,
                    services: services,
                    timelines: state.timelines
                )
                candidate = created
                guard self.isCurrentReconstructionGeneration(generation) else {
                    candidate = nil
                    await self.backendRetirementSupervisor.retire(
                        [(id: ascendantID, backend: created)],
                        stage: .reconstructionCandidate
                    )
                    throw NodeRuntimeError.notRunning
                }
                try created.validateConfiguration()
                let projected = try await created.operatedTimelines()
                try Self.validateReplacement(
                    candidate: created,
                    projected: projected,
                    spec: spec,
                    state: state
                )
                guard self.isCurrentReconstructionGeneration(generation) else {
                    candidate = nil
                    await self.backendRetirementSupervisor.retire(
                        [(id: ascendantID, backend: created)],
                        stage: .reconstructionCandidate
                    )
                    throw NodeRuntimeError.notRunning
                }
                let currentRevision = await self.registry.backendRevision(for: ascendantID)
                guard self.isCurrentReconstructionGeneration(generation) else {
                    candidate = nil
                    await self.backendRetirementSupervisor.retire(
                        [(id: ascendantID, backend: created)],
                        stage: .reconstructionCandidate
                    )
                    throw NodeRuntimeError.notRunning
                }
                guard currentRevision == state.revision else {
                    candidate = nil
                    await self.backendRetirementSupervisor.retire(
                        [(id: ascendantID, backend: created)],
                        stage: .reconstructionCandidate
                    )
                    throw BackendReconstructionFailure(detail: "registry changed during reconstruction")
                }

                // Publication is part of the shared reconstruction task. Every
                // waiter receives this installed instance only after the
                // generation and the exact captured revision have been fenced.
                guard await self.registry.activateBackendLease(lease, for: ascendantID, generation: generation) else {
                    candidate = nil
                    await self.backendRetirementSupervisor.retire(
                        [(id: ascendantID, backend: created)],
                        stage: .reconstructionCandidate
                    )
                    throw NodeRuntimeError.notRunning
                }
                guard self.isCurrentReconstructionGeneration(generation) else {
                    await self.registry.invalidateBackendLease(for: ascendantID)
                    candidate = nil
                    await self.backendRetirementSupervisor.retire(
                        [(id: ascendantID, backend: created)],
                        stage: .reconstructionCandidate
                    )
                    throw NodeRuntimeError.notRunning
                }
                self.backendLeases[ascendantID] = lease
                self.ascendantAdapters[ascendantID] = created
                self.backendHealthByID[ascendantID] = .healthy
                self.timelineService.restoreBackend(ascendantID)
                self.workspaceService.restoreBackend(ascendantID)
                self.readvertiseAscendant(ascendantID, health: .healthy)
                candidate = nil
                return created
            } catch {
                if let candidate {
                    await self.backendRetirementSupervisor.retire(
                        [(id: ascendantID, backend: candidate)],
                        stage: .reconstructionCandidate
                    )
                }
                guard generation == self.lifetime.generation, self.lifetime.state == .running else {
                    throw error
                }
                self.backendHealthByID[ascendantID] = .failed
                self.readvertiseAscendant(ascendantID, health: .failed)
                if let failure = error as? BackendReconstructionFailure {
                    throw failure
                }
                throw BackendReconstructionFailure(detail: error.localizedDescription)
            }
        }
        lifetime.reconstructionTasks[ascendantID] = task
        do {
            let backend = try await task.value
            lifetime.reconstructionTasks.removeValue(forKey: ascendantID)
            return backend
        } catch {
            lifetime.reconstructionTasks.removeValue(forKey: ascendantID)
            throw error
        }
    }

    private func readvertiseAscendant(_ ascendantID: UUID, health: AscendantBackendHealth) {
        guard let identity = backendIdentities.first(where: { $0.id == ascendantID }) else { return }
        projectionRelay.projectAscendant(identity, health: health, replacing: true)
    }

    private func isCurrentReconstructionGeneration(_ generation: UInt64) -> Bool {
        generation == lifetime.generation && lifetime.state == .running && !Task.isCancelled
    }

    private static func validateReplacement(
        candidate: any AscendantBackend,
        projected: [AscendantBackendTimeline],
        spec: BackendSpec,
        state: NodeRegistry.BackendReconstructionState
    ) throws {
        guard candidate.identity.id == spec.ascendant.id,
              candidate.identity.privateTimelineID == spec.ascendant.defaultTimelineID else {
            throw NodeRuntimeError.unknownAscendant(candidate.identity.id)
        }
        let expectedIDs = Set(state.timelines.map(\.id))
        let projectedIDs = Set(projected.map(\.id))
        guard expectedIDs.isSubset(of: projectedIDs) else {
            let missing = expectedIDs.subtracting(projectedIDs).first!
            throw NodeRuntimeError.missingTimeline(missing)
        }
        for timeline in projected where expectedIDs.contains(timeline.id) {
            guard timeline.attachedAscendantID == spec.ascendant.id else {
                throw NodeRuntimeError.unknownAscendant(timeline.attachedAscendantID ?? spec.ascendant.id)
            }
        }
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
        guard lifetime.state == .starting, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func requireActiveRunningStart() throws {
        guard lifetime.state == .running, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func rollbackStart(close: Bool) async {
        if let cleanupTask = lifetime.cleanupTask {
            await cleanupTask.value
            return
        }
        guard let cleanup = lifetime.beginCleanup(close: close) else {
            return
        }
        let cleanupTask = Task { @MainActor [weak self, cleanup] in
            guard let self else { return }
            await self.performCleanup(cleanup)
        }
        lifetime.cleanupTask = cleanupTask
        await cleanupTask.value
        lifetime.cleanupTask = nil
        lifetime.markCleanupCompleted()
    }

    private func performCleanup(_ cleanup: NodeRuntimeLifetime.CleanupTasks) async {
        await registry.fenceBackendLeases(at: lifetime.generation)
        backendLeases.removeAll()
        transport.cancel()
        await permissionCoordinator.denyAll(reason: "connection_lost")
        cleanup.reconstructions.forEach { $0.cancel() }
        await turnCoordinator.cancelAll(waitForCompletion: false)
        await turnUpdates.finish()
        let adapters = ascendantAdapters.map { (id: $0.key, backend: $0.value) }
        for adapter in adapters {
            backendHealthByID[adapter.id] = .unknown
        }
        ascendantAdapters.removeAll()
        await backendRetirementSupervisor.retire(adapters, stage: .runtimeShutdown)
        cleanup.publishTask?.cancel()
        await cleanup.publishTask?.value
        cleanup.resolutionTask?.cancel()
        subscription.stop()
        container.shutdown()
    }

    private static func validate(plan: NodeLaunchPlan) throws {
        let manifest = NodeManifest(schemaVersion: NodeManifest.currentSchemaVersion, broker: plan.broker, node: plan.node, ascendants: plan.ascendants, timelines: plan.timelines, workspaces: plan.workspaces)
        try manifest.validate()
    }

    private static func timeline(from configuration: NodeManifest.Timeline, ascendantID: UUID?) throws -> AscendantRuntimeTimeline {
        let now = Date()
        return .init(id: configuration.id, title: configuration.title, attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID), attachedAscendantID: ascendantID, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
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
