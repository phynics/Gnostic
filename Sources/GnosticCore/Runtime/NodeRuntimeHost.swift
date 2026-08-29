// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Owns the concrete host resources and lifecycle side effects for a node.
/// NodeRuntime remains a public facade over the canonical registry and domain
/// services; it does not own transport, broker, or publication cleanup.
@MainActor
final class NodeRuntimeHost {
    struct TransportWiring {
        let ascendantIdentities: @MainActor () -> [AscendantRuntimeIdentity]
        let ascendantHealth: @MainActor (UUID) -> AscendantBackendHealth
        let workspaceReferences: @MainActor () async -> [GnosticWorkspaceReference]
        let localWorkspaces: [UUID: any WorkspaceProvider]
        let isAvailable: @MainActor () -> Bool
        let turn: NodeTransport.Turn
        let timelineStatus: NodeTransport.TimelineStatusLookup
        let selectAscendant: NodeTransport.AscendantSelection
        let createTimeline: NodeTransport.TimelineCreation
        let listTimelines: NodeTransport.TimelineList
        let renameTimeline: NodeTransport.TimelineRename
        let listWorkspaces: NodeTransport.WorkspaceList
        let attachWorkspace: NodeTransport.WorkspaceMutation
        let detachWorkspace: NodeTransport.WorkspaceMutation
    }

    let lifecycleCoordinator: RuntimeLifecycleCoordinator
    let lifetime: NodeRuntimeLifetime
    let resources: NodeAssembly.Infrastructure

    private let adapters: NodeRuntimeAdapters
    private let turnUpdates: AscendantTurnUpdateStore
    private let permissionCoordinator: AscendantPermissionCoordinator
    private let turnCoordinator: AscendantTurnCoordinator
    private let projectionRelay: NodeProjectionRelay
    private var registry: NodeRegistry?
    private var backendSupervisor: AscendantBackendSupervisor?
    private var transport: NodeTransport?
    private var refreshUnresolved: (@MainActor () async -> Void)?

    init(
        lifecycleCoordinator: RuntimeLifecycleCoordinator,
        resources: NodeAssembly.Infrastructure,
        adapters: NodeRuntimeAdapters,
        turnUpdates: AscendantTurnUpdateStore,
        permissionCoordinator: AscendantPermissionCoordinator,
        turnCoordinator: AscendantTurnCoordinator,
        projectionRelay: NodeProjectionRelay
    ) {
        self.lifecycleCoordinator = lifecycleCoordinator
        lifetime = lifecycleCoordinator.lifetime
        self.resources = resources
        self.adapters = adapters
        self.turnUpdates = turnUpdates
        self.permissionCoordinator = permissionCoordinator
        self.turnCoordinator = turnCoordinator
        self.projectionRelay = projectionRelay
    }

    var isRunning: Bool { lifetime.isRunning }

    func configure(
        registry: NodeRegistry,
        backendSupervisor: AscendantBackendSupervisor,
        wiring: TransportWiring,
        refreshUnresolved: @escaping @MainActor () async -> Void
    ) {
        self.registry = registry
        self.backendSupervisor = backendSupervisor
        transport = NodeTransport(
            communication: resources.communication,
            lifecycle: resources.lifecycle,
            registry: registry,
            ascendantIdentities: wiring.ascendantIdentities,
            ascendantHealth: wiring.ascendantHealth,
            workspaceReferences: wiring.workspaceReferences,
            localWorkspaces: wiring.localWorkspaces,
            isAvailable: wiring.isAvailable,
            turn: wiring.turn,
            timelineStatus: wiring.timelineStatus,
            selectAscendant: wiring.selectAscendant,
            createTimeline: wiring.createTimeline,
            listTimelines: wiring.listTimelines,
            renameTimeline: wiring.renameTimeline,
            listWorkspaces: wiring.listWorkspaces,
            attachWorkspace: wiring.attachWorkspace,
            detachWorkspace: wiring.detachWorkspace
        )
        self.refreshUnresolved = refreshUnresolved
    }

    func start() async throws {
        guard registry != nil, backendSupervisor != nil, transport != nil else {
            throw NodeRuntimeError.notRunning
        }
        try await lifecycleCoordinator.start(
            prepare: { [weak self] generation in
                guard let self, let registry = self.registry else { return }
                await registry.setLifecycleGeneration(generation)
            },
            operation: { [weak self] in
                guard let self else { throw NodeRuntimeError.notRunning }
                try await self.performStart()
            }
        )
    }

    func shutdown() async {
        // Interrupt the broker handshake before the coordinator waits for
        // startup. Axoloty's transport teardown is continuation-backed and
        // must be signalled before lifecycle cleanup can join the task.
        resources.container.shutdown()
        await lifecycleCoordinator.shutdown { [weak self] cleanup in
            await self?.performCleanup(cleanup)
        }
    }

    private func performStart() async throws {
        guard registry != nil, backendSupervisor != nil, let transport else {
            throw NodeRuntimeError.notRunning
        }
        do {
            projectionRelay.bind(transport)
            try await resources.container.startAndWaitUntilReady()
            try requireActiveStart()
            try adapters.lifecycle.afterConnection()
            try await resources.subscription.start()
            try requireActiveStart()
            startNetworkResolution()
            try await transport.registerOperations(
                turnUpdates: turnUpdates,
                permissionCoordinator: permissionCoordinator
            )

            let events = await turnUpdates.events()
            lifetime.turnUpdatePublishTask = Task { [communication = resources.communication] in
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

    private func startNetworkResolution() {
        lifetime.networkResolutionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.lifetime.state != .closed else { return }
                await self.refreshUnresolved?()
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
        guard let registry, let backendSupervisor, let transport else { return }
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
        resources.subscription.stop()
        resources.container.shutdown()
    }
}
