// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Broker-facing forwarding boundary. It is intentionally unable to access a
/// registry, adapter, or provider-native object directly.
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

    private let isAvailable: @MainActor () -> Bool
    private weak var operations: (any NodeOperations)?
    private let communication: CommunicationManager?
    private let lifecycle: ObjectLifecycleController?
    private let registry: NodeRegistry?
    private let nodeID: UUID?
    private let runtimeInstanceObjects: @MainActor () -> [GnosticRuntimeInstanceObject]
    private let workspaceReferences: @MainActor () async -> [GnosticWorkspaceReference]
    private let workspaceAuthorization: @MainActor @Sendable (String?, UUID?, UUID) async -> Bool
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
        nodeID: UUID? = nil,
        runtimeInstanceObjects: @escaping @MainActor () -> [GnosticRuntimeInstanceObject] = { [] },
        workspaceReferences: @escaping @MainActor () async -> [GnosticWorkspaceReference] = { [] },
        workspaceAuthorization: @escaping @MainActor @Sendable (String?, UUID?, UUID) async -> Bool = { _, _, _ in false },
        workspaceAdmission: @escaping @MainActor @Sendable (String?, UUID?, UUID) async -> Bool = { _, _, _ in false },
        localWorkspaces: [UUID: any LocalWorkspace] = [:],
        isAvailable: @escaping @MainActor () -> Bool,
        operations: any NodeOperations,
        hooks: TestHooks = .none
    ) {
        self.communication = communication
        self.lifecycle = lifecycle
        self.registry = registry
        self.nodeID = nodeID
        self.runtimeInstanceObjects = runtimeInstanceObjects
        self.workspaceReferences = workspaceReferences
        self.workspaceAuthorization = workspaceAuthorization
        workspaceProvider = localWorkspaces.isEmpty ? nil : MultiplexedWorkspaceProvider(
            workspaces: localWorkspaces,
            workspaceStatus: { id in await registry?.effectiveWorkspaceStatus(id: id) },
            setWorkspaceStatus: { id, status in
                guard await registry?.setWorkspaceStatus(id: id, status: status) == true else { return false }
                guard let reference = await workspaceReferences().first(where: { $0.id == id }) else { return false }
                await lifecycle?.readvertiseDiscoverableObjectAndWait(object: GnosticWorkspaceObject(workspace: reference))
                return true
            },
            callerBoundAuthorization: { sourceID, timelineID, workspaceID in
                await workspaceAuthorization(sourceID, timelineID, workspaceID)
            },
            admitInvocation: { sourceID, timelineID, workspaceID in
                await workspaceAdmission(sourceID, timelineID, workspaceID)
            },
            isAvailable: { await isAvailable() }
        )
        self.isAvailable = isAvailable
        self.operations = operations
        scope = try! RuntimeEffectScope(name: "node-transport")
        registrationScope = try! RuntimeEffectScope(name: "transport-registrations")
        responderScope = try! RuntimeEffectScope(name: "transport-responders")
        permissionScope = try! RuntimeEffectScope(name: "transport-permission")
        advertisementScope = try! RuntimeEffectScope(name: "transport-advertisements")
        self.hooks = hooks
    }

    public func turn(_ request: TurnRequest) async throws -> TurnResult {
        guard let operations else { throw NodeRuntimeError.notRunning }
        return try await operations.turn(request)
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
                _ = try await registrationScope.acquire(
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
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.turn(request)
                },
                cancel: { [weak self] request in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { return false }
                    return await operations.cancelTurn(request)
                },
                replayStore: turnUpdates,
                isAvailable: { [weak self] in await self?.isAvailable() == true }
            )
            try hooks.beforeRegistration("turn")
            _ = try await registrationScope.acquire(
                label: "turn",
                acquire: { try await turnProvider.register(on: communication, context: context) },
                cleanup: { registrations in registrations.forEach { $0.cancel() } }
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
                guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                return try await operations.timelineStatus(for: request.timelineID)
            }
            try hooks.beforeRegistration("timeline-status")
            _ = try await registrationScope.acquire(
                label: "timeline-status",
                acquire: { try await status.register(on: communication, context: context) },
                cleanup: { registration in registration.cancel() }
            )

            let management = TimelineManagementProvider(
                create: { [weak self] title, ascendantID in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    let selectedID = try await operations.selectAscendant(requested: ascendantID)
                    return try await operations.createTimeline(title: title, ascendantID: selectedID)
                },
                list: { [weak self] in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.listTimelines()
                },
                update: { [weak self] request in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.renameTimeline(request)
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
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return await operations.listWorkspaces()
                },
                attach: { [weak self] request in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.attachWorkspace(request)
                },
                detach: { [weak self] request in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.detachWorkspace(request)
                }
            )
            try hooks.beforeRegistration("workspace-operations")
            _ = try await registrationScope.acquire(
                label: "workspace-operations",
                acquire: { try await workspace.register(on: communication, context: context) },
                cleanup: { registrations in registrations.forEach { $0.cancel() } }
            )

            let diagnostics = DiagnosticsProvider(
                node: { [weak self] in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.diagnosticsNode()
                },
                runtimeInstance: { [weak self] ascendantID in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.diagnosticsAscendant(ascendantID)
                },
                timeline: { [weak self] timelineID in
                    guard let self, await self.isAvailable(), let operations = await self.operations else { throw NodeRuntimeError.notRunning }
                    return try await operations.diagnosticsTimeline(timelineID)
                }
            )
            try hooks.beforeRegistration("diagnostics")
            _ = try await registrationScope.acquire(
                label: "diagnostics",
                acquire: { try await diagnostics.register(on: communication, context: context) },
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
                acquire: { [self] in
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
        let object = GnosticTimelineObject(timeline: timeline, nodeID: nodeID)
        advertisedObjects[object.objectId.string] = object
        if replacing { lifecycle.readvertiseDiscoverableObject(object: object) }
        else { lifecycle.advertiseDiscoverableObject(object: object) }
    }

    func projectRuntimeInstance(_ instance: GnosticRuntimeInstanceObject, replacing: Bool) {
        guard isAvailable(), let lifecycle, advertisementTeardownInstalled else { return }
        let object = networkRuntimeInstance(from: instance)
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

    /// Gives the host scope one structural owner for transport resources.
    func adopt(into parent: RuntimeEffectScope) async throws {
        _ = try await parent.adopt(scope, label: "transport")
    }

    private func discoverableObjects() async -> [CoatyObject] {
        var objects: [CoatyObject] = []
        if let registry {
            objects += await registry.listTimelines().map { GnosticTimelineObject(timeline: $0, nodeID: nodeID) }
        }
        objects += runtimeInstanceObjects().map(networkRuntimeInstance(from:))
        objects += await workspaceReferences().map { GnosticWorkspaceObject(workspace: $0) }
        return objects
    }

    private func networkRuntimeInstance(from instance: GnosticRuntimeInstanceObject) -> GnosticRuntimeInstanceObject {
        GnosticRuntimeInstanceObject(
            id: instance.runtimeID,
            name: instance.name,
            kind: instance.runtimeKind,
            nodeID: nodeID,
            version: instance.runtimeVersion,
            launchFingerprint: instance.launchFingerprint,
            health: instance.health,
            rawCapabilities: instance.rawCapabilities,
            protocolMajor: instance.protocolMajor
        )
    }

    func cancel() async {
        advertisementTeardownInstalled = false
        _ = await scope.dispose()
    }
}
