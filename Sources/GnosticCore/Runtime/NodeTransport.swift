// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Broker-facing forwarding boundary. It is intentionally unable to access a
/// registry, adapter, or PositronicKit object directly.
@MainActor
public final class NodeTransport {
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
    private let workspaceReferences: @MainActor () async -> [WorkspaceReference]
    private let workspaceProvider: MultiplexedWorkspaceProvider?
    private var registrations: [CallHandlerRegistration] = []
    private var discoverResponder: DiscoverResponderRegistration?
    private var permissionResponses: Task<Void, Never>?
    private var advertisedObjects: [String: CoatyObject] = [:]

    init(
        communication: CommunicationManager? = nil,
        lifecycle: ObjectLifecycleController? = nil,
        registry: NodeRegistry? = nil,
        ascendantIdentities: @escaping @MainActor () -> [AscendantRuntimeIdentity] = { [] },
        ascendantHealth: @escaping @MainActor (UUID) -> AscendantBackendHealth = { _ in .unknown },
        workspaceReferences: @escaping @MainActor () async -> [WorkspaceReference] = { [] },
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
        detachWorkspace: @escaping WorkspaceMutation
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
    }

    public func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try await turnOperation(request)
    }

    func registerOperations(
        turnUpdates: AscendantTurnUpdateStore,
        permissionCoordinator: AscendantPermissionCoordinator
    ) async throws {
        guard let communication else { throw NodeRuntimeError.notRunning }
        if let workspaceProvider {
            registrations.append(try await workspaceProvider.register(on: communication))
        }
        let turnProvider = AscendantTurnProvider(
            execute: { [weak self] request in
                guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                return try await self.turn(request)
            },
            replayStore: turnUpdates,
            isAvailable: { [weak self] in await self?.isAvailable() == true }
        )
        registrations.append(try await turnProvider.register(on: communication, context: communication.identity))
        registrations.append(try await turnProvider.registerReplay(on: communication, context: communication.identity))

        let permission = AscendantPermissionProvider(coordinator: permissionCoordinator)
        registrations.append(try await permission.register(on: communication, context: communication.identity))
        permissionResponses = try await permission.observeResponses(on: communication, providerID: communication.identity.objectId.string)

        let status = TimelineStatusProvider { [weak self] request in
            guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
            return try await self.timelineStatusOperation(request.timelineID)
        }
        registrations.append(try await status.register(on: communication, context: communication.identity))

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
        registrations += try await management.register(on: communication, context: communication.identity)

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
        registrations += try await workspace.register(on: communication, context: communication.identity)
    }

    func registerDiscoverResponder() async {
        guard let communication else { return }
        discoverResponder = await communication.registerDiscoverResponder { [weak self] request in
            guard let self, self.isAvailable() else { return }
            let types = request.snapshot.objectTypes
            for object in await self.discoverableObjects()
                where types == nil || types?.contains(object.objectType) == true {
                try request.resolve(object: object)
            }
        }
    }

    func advertiseAll() async {
        guard let lifecycle else { return }
        for object in await discoverableObjects() {
            advertisedObjects[object.objectId.string] = object
            lifecycle.advertiseDiscoverableObject(object: object)
        }
    }

    func projectTimeline(_ timeline: AscendantRuntimeTimeline, replacing: Bool) {
        guard isAvailable(), let lifecycle else { return }
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
        guard isAvailable(), let lifecycle else { return }
        let object = GnosticAscendantObject(identity: identity, backendHealth: health)
        advertisedObjects[object.objectId.string] = object
        if replacing { lifecycle.readvertiseDiscoverableObject(object: object) }
        else { lifecycle.advertiseDiscoverableObject(object: object) }
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
        discoverResponder?.cancel()
        discoverResponder = nil
        registrations.forEach { $0.cancel() }
        registrations.removeAll()
        let responses = permissionResponses
        permissionResponses = nil
        responses?.cancel()
        await responses?.value
        if let lifecycle {
            advertisedObjects.values.forEach { lifecycle.deadvertiseDiscoverableObject(object: $0) }
        }
        advertisedObjects.removeAll()
    }
}
