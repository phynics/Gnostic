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
        /// The manifest node identity advertised alongside every projection.
        let nodeID: UUID
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
    private let scope: RuntimeEffectScope
    private let publisherScope: RuntimeEffectScope
    private let resolutionScope: RuntimeEffectScope
    private var scopesAdopted = false

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
        scope = try! RuntimeEffectScope(name: "node-runtime-host")
        publisherScope = try! RuntimeEffectScope(name: "turn-update-publisher")
        resolutionScope = try! RuntimeEffectScope(name: "network-resolution")
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
            nodeID: wiring.nodeID,
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
        // Shutdown is a completion boundary, not a cancellation request. The
        // shield keeps a cancelled caller from skipping the cleanup handoff
        // before the coordinator owns it.
        await withCancellationShield {
            // Interrupt only a pending broker handshake before the coordinator
            // waits for startup. A running transport must first drain its tracked
            // deadvertisements during cleanup.
            if lifetime.state == .starting {
                resources.container.shutdown()
            }
            await lifecycleCoordinator.shutdown { [weak self] in
                await self?.performCleanup()
            }
        }
    }

    private func performStart() async throws {
        guard registry != nil, backendSupervisor != nil, let transport else {
            throw NodeRuntimeError.notRunning
        }
        do {
            try await adoptComponentScopes()
            projectionRelay.bind(transport)
            try await resources.container.startAndWaitUntilReady()
            try requireActiveStart()
            try adapters.lifecycle.afterConnection()
            try await resources.subscription.start()
            try requireActiveStart()
            try await startNetworkResolution()
            try await transport.registerOperations(
                turnUpdates: turnUpdates,
                permissionCoordinator: permissionCoordinator
            )

            let events = await turnUpdates.events()
            _ = try await publisherScope.task(
                label: "turn-update-publisher"
            ) { @MainActor [communication = resources.communication] in
                for await event in events {
                    guard let channel = try? AscendantTurnProvider.updateEvent(event) else { continue }
                    communication.publishChannel(channel)
                }
            }

            try requireActiveStart()
            try adapters.lifecycle.afterRegistration()
            try await adapters.lifecycle.beforeDiscoverResponder()
            try await transport.registerDiscoverResponder()
            try await adapters.lifecycle.afterDiscoverResponder()
            try requireActiveStart()
            try adapters.lifecycle.beforeAdvertisement()
            lifetime.markRunning()
            try await transport.advertiseAll()
            try await adapters.lifecycle.afterAdvertisement()
            try requireActiveRunningStart()
        } catch {
            let shutdownWon = lifetime.state == .closed
            await lifecycleCoordinator.rollback(close: true) { [weak self] in
                await self?.performCleanup()
            }
            if shutdownWon {
                throw NodeRuntimeError.notRunning
            }
            if let scopeError = error as? RuntimeEffectScopeError {
                switch scopeError {
                case .acquisitionClosed, .registrationRejected:
                    throw NodeRuntimeError.notRunning
                case .invalidName, .invalidLabel, .invalidAdoption:
                    break
                }
            }
            throw error
        }
    }

    private func startNetworkResolution() async throws {
        _ = try await resolutionScope.task(label: "network-resolution") { @MainActor [weak self] in
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

    private func performCleanup() async {
        guard let registry, let backendSupervisor, let transport else { return }
        await registry.fenceBackendLeases(at: lifetime.generation)
        await permissionCoordinator.denyAll(reason: .connectionLost)
        await transport.cancel()
        backendSupervisor.cancelReconstructions()
        await turnCoordinator.cancelAll(waitForCompletion: false)
        await turnUpdates.finish()
        await backendSupervisor.retireAll(stage: .runtimeShutdown)
        // Cancel subscription loops while scopes are still active so their
        // per-effect cleanup runs deterministically; host-scope disposal
        // then reaps the (now empty) adopted subscription scope.
        // These effects follow the existing domain cleanup order explicitly.
        await resources.subscription.stopAndWait()
        _ = await publisherScope.dispose()
        _ = await resolutionScope.dispose()
        _ = await scope.dispose()
        await resources.subscription.disposeScope()
        await resources.container.shutdownAndWait()
    }

    /// Returns internal ownership diagnostics with static labels and no payloads.
    func effectSnapshots() async -> [RuntimeEffectSnapshot] {
        await [scope.snapshot(), publisherScope.snapshot(), resolutionScope.snapshot()]
    }

    /// Returns all component ownership diagnostics for lifecycle verification.
    func allEffectSnapshots() async -> [RuntimeEffectSnapshot] {
        var snapshots = await effectSnapshots()
        if let transport {
            snapshots.append(contentsOf: await transport.effectSnapshots())
        }
        snapshots.append(await resources.subscription.effectSnapshot())
        return snapshots
    }

    private func adoptComponentScopes() async throws {
        guard !scopesAdopted else { return }
        guard let transport else { throw NodeRuntimeError.notRunning }
        let subscription = resources.subscription
        let publisherScope = self.publisherScope
        let resolutionScope = self.resolutionScope
        try await scope.withAcquisition { owner in
            try await subscription.adopt(into: owner)
            try await transport.adopt(into: owner)
            _ = try await owner.adopt(publisherScope, label: "turn-update-publisher")
            _ = try await owner.adopt(resolutionScope, label: "network-resolution")
        }
        scopesAdopted = true
    }
}
