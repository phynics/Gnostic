// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Broker-facing forwarding boundary. It is intentionally unable to access a
/// registry, adapter, or PositronicKit object directly.
@MainActor
public final class NodeTransport {
    /// Internal fault-injection points keep rollback tests at the transport
    /// seam without changing the CommunicationManager contract.
    struct TestHooks {
        let beforeRegistration: @MainActor @Sendable (String) throws -> Void
        let beforeDiscoverResponder: @MainActor @Sendable () throws -> Void

        init(
            beforeRegistration: @escaping @MainActor @Sendable (String) throws -> Void = { _ in },
            beforeDiscoverResponder: @escaping @MainActor @Sendable () throws -> Void = {}
        ) {
            self.beforeRegistration = beforeRegistration
            self.beforeDiscoverResponder = beforeDiscoverResponder
        }

        static let none = Self(
            beforeRegistration: { _ in },
            beforeDiscoverResponder: {}
        )
    }

    typealias Turn = @MainActor (AscendantTurnRequest) async throws -> AscendantTurnResult
    typealias TimelineStatusLookup = @MainActor (UUID) async throws -> TimelineStatus
    typealias AscendantSelection = @MainActor (UUID?) throws -> UUID
    typealias TimelineCreation = @MainActor (String, UUID) async throws -> TimelineStatus
    typealias TimelineList = @MainActor () async throws -> [TimelineStatus]
    typealias TimelineRename = @MainActor (TimelineUpdateRequest) async throws -> TimelineStatus
    typealias WorkspaceList = @MainActor () async -> [WorkspaceListing]
    typealias WorkspaceMutation = @MainActor (WorkspaceOpsRequest) async throws -> Bool

    private let isAvailable: @MainActor () -> Bool
    private let turnOperation: Turn
    private let timelineStatusOperation: TimelineStatusLookup
    private let selectAscendantOperation: AscendantSelection
    private let createTimelineOperation: TimelineCreation
    private let listTimelinesOperation: TimelineList
    private let renameTimelineOperation: TimelineRename
    private let listWorkspacesOperation: WorkspaceList
    private let attachWorkspaceOperation: WorkspaceMutation
    private let detachWorkspaceOperation: WorkspaceMutation
    private let communication: CommunicationManager?
    private let lifecycle: ObjectLifecycleController?
    private let registry: NodeRegistry?
    private let ascendantIdentities: @MainActor () -> [AscendantRuntimeIdentity]
    private let ascendantHealth: @MainActor (UUID) -> AscendantBackendHealth
    private let workspaceReferences: @MainActor () async -> [GnosticWorkspaceReference]
    private let workspaceProvider: MultiplexedWorkspaceProvider?
    private let scope: RuntimeEffectScope
    private let registrationScope: RuntimeEffectScope
    private let responderScope: RuntimeEffectScope
    private let permissionScope: RuntimeEffectScope
    private let advertisementScope: RuntimeEffectScope
    private let hooks: TestHooks
    private var scopesAdopted = false
    private var advertisementTeardownInstalled = false
    private var advertisedObjects: [String: CoatyObject] = [:]

    init(
        communication: CommunicationManager? = nil,
        lifecycle: ObjectLifecycleController? = nil,
        registry: NodeRegistry? = nil,
        ascendantIdentities: @escaping @MainActor () -> [AscendantRuntimeIdentity] = { [] },
        ascendantHealth: @escaping @MainActor (UUID) -> AscendantBackendHealth = { _ in .unknown },
        workspaceReferences: @escaping @MainActor () async -> [GnosticWorkspaceReference] = { [] },
        localWorkspaces: [UUID: any WorkspaceProvider] = [:],
        isAvailable: @escaping @MainActor () -> Bool,
        turn: @escaping Turn,
        timelineStatus: @escaping TimelineStatusLookup,
        selectAscendant: @escaping AscendantSelection,
        createTimeline: @escaping TimelineCreation,
        listTimelines: @escaping TimelineList,
        renameTimeline: @escaping TimelineRename,
        listWorkspaces: @escaping WorkspaceList,
        attachWorkspace: @escaping WorkspaceMutation,
        detachWorkspace: @escaping WorkspaceMutation,
        hooks: TestHooks = .none
    ) {
        self.communication = communication
        self.lifecycle = lifecycle
        self.registry = registry
        self.ascendantIdentities = ascendantIdentities
        self.ascendantHealth = ascendantHealth
        self.workspaceReferences = workspaceReferences
        workspaceProvider = localWorkspaces.isEmpty ? nil : MultiplexedWorkspaceProvider(workspaces: localWorkspaces) {
            await isAvailable()
        }
        self.isAvailable = isAvailable
        turnOperation = turn
        timelineStatusOperation = timelineStatus
        selectAscendantOperation = selectAscendant
        createTimelineOperation = createTimeline
        listTimelinesOperation = listTimelines
        renameTimelineOperation = renameTimeline
        listWorkspacesOperation = listWorkspaces
        attachWorkspaceOperation = attachWorkspace
        detachWorkspaceOperation = detachWorkspace
        scope = try! RuntimeEffectScope(name: "node-transport")
        registrationScope = try! RuntimeEffectScope(name: "transport-registrations")
        responderScope = try! RuntimeEffectScope(name: "transport-responders")
        permissionScope = try! RuntimeEffectScope(name: "transport-permission")
        advertisementScope = try! RuntimeEffectScope(name: "transport-advertisements")
        self.hooks = hooks
    }

    public func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try await turnOperation(request)
    }

    func registerOperations(
        turnUpdates: AscendantTurnUpdateStore,
        permissionCoordinator: AscendantPermissionCoordinator
    ) async throws {
        guard let communication else { throw NodeRuntimeError.notRunning }
        try await adoptComponentScopes()
        do {
            try await ensureAdvertisementTeardown()
            let context = communication.identity
            if let workspaceProvider {
                try hooks.beforeRegistration("workspace-handler")
                _ = try await responderScope.acquire(
                    label: "workspace-handler",
                    acquire: { try await workspaceProvider.register(on: communication) },
                    cleanup: { registration in registration.cancel() }
                )
                try hooks.beforeRegistration("workspace-query-responder")
                _ = try await responderScope.acquire(
                    label: "workspace-query-responder",
                    acquire: { await workspaceProvider.registerQuery(on: communication) },
                    cleanup: { registration in registration.cancel() }
                )
            }

            let turnProvider = AscendantTurnProvider(
                execute: { [weak self] request in
                    guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                    return try await self.turn(request)
                },
                replayStore: turnUpdates,
                isAvailable: { [weak self] in await self?.isAvailable() == true }
            )
            try hooks.beforeRegistration("ascendant-turn")
            _ = try await registrationScope.acquire(
                label: "ascendant-turn",
                acquire: { try await turnProvider.register(on: communication, context: context) },
                cleanup: { registration in registration.cancel() }
            )
            try hooks.beforeRegistration("ascendant-turn-replay")
            _ = try await registrationScope.acquire(
                label: "ascendant-turn-replay",
                acquire: { try await turnProvider.registerReplay(on: communication, context: context) },
                cleanup: { registration in registration.cancel() }
            )

            let permission = AscendantPermissionProvider(coordinator: permissionCoordinator)
            try hooks.beforeRegistration("permission-handler")
            _ = try await registrationScope.acquire(
                label: "permission-handler",
                acquire: { try await permission.register(on: communication, context: context) },
                cleanup: { registration in registration.cancel() }
            )
            try hooks.beforeRegistration("permission-observation")
            _ = try await permissionScope.acquire(
                label: "permission-observation",
                acquire: { try await permission.observeResponses(on: communication, providerID: context.objectId.string) },
                cleanup: { task in
                    task.cancel()
                    _ = await task.result
                }
            )

            let status = TimelineStatusProvider { [weak self] request in
                guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                return try await self.timelineStatusOperation(request.timelineID)
            }
            try hooks.beforeRegistration("timeline-status")
            _ = try await registrationScope.acquire(
                label: "timeline-status",
                acquire: { try await status.register(on: communication, context: context) },
                cleanup: { registration in registration.cancel() }
            )

            let management = TimelineManagementProvider(
                create: { [weak self] title, ascendantID in
                    guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                    let selectedID = try await self.selectAscendantOperation(ascendantID)
                    return try await self.createTimelineOperation(title, selectedID)
                },
                list: { [weak self] in
                    guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                    return try await self.listTimelinesOperation()
                },
                update: { [weak self] request in
                    guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                    return try await self.renameTimelineOperation(request)
                }
            )
            try hooks.beforeRegistration("timeline-management")
            _ = try await registrationScope.acquire(
                label: "timeline-management",
                acquire: { try await management.register(on: communication, context: context) },
                cleanup: { registrations in registrations.forEach { $0.cancel() } }
            )

            let workspace = WorkspaceOpsProvider(
                list: { [weak self] in
                    guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                    return await self.listWorkspacesOperation()
                },
                attach: { [weak self] request in
                    guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                    return try await self.attachWorkspaceOperation(request)
                },
                detach: { [weak self] request in
                    guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                    return try await self.detachWorkspaceOperation(request)
                }
            )
            try hooks.beforeRegistration("workspace-operations")
            _ = try await registrationScope.acquire(
                label: "workspace-operations",
                acquire: { try await workspace.register(on: communication, context: context) },
                cleanup: { registrations in registrations.forEach { $0.cancel() } }
            )
        } catch {
            await cancel()
            throw error
        }
    }

    func registerDiscoverResponder() async throws {
        guard let communication else { return }
        try await adoptComponentScopes()
        do {
            try hooks.beforeDiscoverResponder()
            _ = try await responderScope.acquire(
                label: "discover-responder",
                acquire: {
                    await communication.registerDiscoverResponder { [weak self] request in
                        guard let self, await self.isAvailable() else { return }
                        let types = request.snapshot.objectTypes
                        for object in await self.discoverableObjects()
                            where types == nil || types?.contains(object.objectType) == true {
                            try request.resolve(object: object)
                        }
                    }
                },
                cleanup: { registration in registration.cancel() }
            )
        } catch {
            await cancel()
            throw error
        }
    }

    func advertiseAll() async throws {
        guard let lifecycle else { return }
        try await ensureAdvertisementTeardown()
        for object in await discoverableObjects() {
            advertisedObjects[object.objectId.string] = object
            lifecycle.advertiseDiscoverableObject(object: object)
        }
    }

    func projectTimeline(_ timeline: AscendantRuntimeTimeline, replacing: Bool) {
        guard isAvailable(), let lifecycle, advertisementTeardownInstalled else { return }
        let object = GnosticTimelineObject(timeline: timeline)
        advertisedObjects[object.objectId.string] = object
        if replacing { lifecycle.readvertiseDiscoverableObject(object: object) }
        else { lifecycle.advertiseDiscoverableObject(object: object) }
    }

    func projectAscendant(
        _ identity: AscendantRuntimeIdentity,
        health: AscendantBackendHealth,
        replacing: Bool
    ) {
        guard isAvailable(), let lifecycle, advertisementTeardownInstalled else { return }
        let object = GnosticAscendantObject(identity: identity, backendHealth: health)
        advertisedObjects[object.objectId.string] = object
        if replacing { lifecycle.readvertiseDiscoverableObject(object: object) }
        else { lifecycle.advertiseDiscoverableObject(object: object) }
    }

    private func adoptComponentScopes() async throws {
        guard !scopesAdopted else { return }
        let advertisementScope = self.advertisementScope
        let permissionScope = self.permissionScope
        let registrationScope = self.registrationScope
        let responderScope = self.responderScope
        try await scope.withAcquisition { owner in
            _ = try await owner.adopt(advertisementScope, label: "advertisements")
            _ = try await owner.adopt(permissionScope, label: "permission")
            _ = try await owner.adopt(registrationScope, label: "registrations")
            _ = try await owner.adopt(responderScope, label: "responders")
        }
        scopesAdopted = true
    }

    private func ensureAdvertisementTeardown() async throws {
        guard lifecycle != nil, !advertisementTeardownInstalled else { return }
        _ = try await advertisementScope.add(label: "advertisement-teardown") { [weak self] in
            await self?.deadvertiseAll()
        }
        advertisementTeardownInstalled = true
    }

    private func deadvertiseAll() async {
        let objects = Array(advertisedObjects.values)
        advertisedObjects.removeAll()
        guard let lifecycle else { return }
        for object in objects {
            await lifecycle.deadvertiseDiscoverableObjectAndWait(object: object)
        }
    }

    func effectSnapshots() async -> [RuntimeEffectSnapshot] {
        await [
            scope.snapshot(),
            advertisementScope.snapshot(),
            permissionScope.snapshot(),
            registrationScope.snapshot(),
            responderScope.snapshot(),
        ]
    }

    private func discoverableObjects() async -> [CoatyObject] {
        var objects: [CoatyObject] = ascendantIdentities().map {
            GnosticAscendantObject(identity: $0, backendHealth: ascendantHealth($0.id))
        }
        if let registry {
            objects += await registry.listTimelines().map { GnosticTimelineObject(timeline: $0) }
        }
        objects += await workspaceReferences().map { GnosticWorkspaceObject(workspace: $0) }
        return objects
    }

    func cancel() async {
        _ = await scope.dispose()
    }
}
