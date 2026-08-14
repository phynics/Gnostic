// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

/// One unary Axoloty handler serving every local Workspace by workspace ID.
///
/// This is transport infrastructure: its registration and cancellation belong
/// to ``NodeTransport`` rather than the node composition root.
public actor MultiplexedWorkspaceProvider {
    public static let invocationOperation = WorkspaceProvider.invocationOperation

    private let workspaces: [UUID: any Workspace]
    private let isAvailable: @Sendable () async -> Bool

    public init(
        workspaces: [UUID: any Workspace],
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.workspaces = workspaces
        self.isAvailable = isAvailable
    }

    public func handle(parameters: String?, expectedProviderID: String? = nil) async throws -> CallHandlerResult {
        guard await isAvailable() else { throw NodeRuntimeError.notRunning }
        guard let parameters else { throw WorkspaceError.toolExecutionNotSupported }
        let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
        if let expectedProviderID, let providerID = invocation.providerID,
           providerID.lowercased() != expectedProviderID.lowercased() {
            throw WorkspaceError.connectionFailed
        }
        guard let workspace = workspaces[invocation.workspaceID] else {
            throw WorkspaceError.workspaceNotFound
        }
        let result = try await workspace.executeTool(id: invocation.toolID, parameters: invocation.arguments)
        return .success(result: String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        let providerID = communication.identity.objectId.string
        return try await communication.registerCallHandler(operation: Self.invocationOperation, context: communication.identity) { [self] request in
            try await handle(parameters: request.parameters, expectedProviderID: providerID)
        }
    }
}

/// Serializes turns independently of the node's transport/lifecycle shell.
@MainActor
public final class ChatTurnService {
    private let adapter: @MainActor (UUID) -> (any AscendantRuntimeAdapter)?
    private let registry: NodeRegistry
    private let coordinator: AscendantTurnCoordinator
    private let updates: AscendantTurnUpdateStore
    private let isRunning: @MainActor () -> Bool

    init(registry: NodeRegistry, coordinator: AscendantTurnCoordinator, updates: AscendantTurnUpdateStore, isRunning: @escaping @MainActor () -> Bool, adapter: @escaping @MainActor (UUID) -> (any AscendantRuntimeAdapter)?) {
        self.registry = registry; self.coordinator = coordinator; self.updates = updates; self.isRunning = isRunning; self.adapter = adapter
    }

    func chat(_ request: AgentChatRequest) async throws -> AgentChatResult {
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        guard let adapter = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        return try await coordinator.execute(request) { [updates] in try await adapter.runTurn(request, updates: updates) }
    }
}

@MainActor
public final class TimelineService {
    private let ascendantIDs: Set<UUID>
    private let registry: NodeRegistry
    private let adapter: @MainActor (UUID) -> (any AscendantRuntimeAdapter)?
    private let isClosed: @MainActor () -> Bool
    private let advertise: @MainActor (AscendantRuntimeTimeline, Bool) -> Void

    init(ascendantIDs: Set<UUID>, registry: NodeRegistry, isClosed: @escaping @MainActor () -> Bool, adapter: @escaping @MainActor (UUID) -> (any AscendantRuntimeAdapter)?, advertise: @escaping @MainActor (AscendantRuntimeTimeline, Bool) -> Void) {
        self.ascendantIDs = ascendantIDs; self.registry = registry; self.isClosed = isClosed; self.adapter = adapter; self.advertise = advertise
    }

    func selectAscendant(requested ascendantID: UUID?) throws -> UUID {
        if let ascendantID {
            guard ascendantIDs.contains(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
            return ascendantID
        }
        guard !ascendantIDs.isEmpty else { throw NodeRuntimeError.noConfiguredAscendant }
        guard ascendantIDs.count == 1 else { throw NodeRuntimeError.ambiguousAscendant }
        return ascendantIDs.first!
    }

    func status(for id: UUID) async throws -> TimelineStatus {
        guard let record = await registry.timeline(id: id) else { throw NodeRuntimeError.missingTimeline(id) }
        return Self.status(record.timeline)
    }
    func create(title: String, ascendantID: UUID) async throws -> TimelineStatus {
        guard !isClosed() else { throw NodeRuntimeError.notRunning }
        guard let adapter = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let reservation = try await registry.registerRuntimeTimeline(title: title, ascendantID: ascendantID)
        var projectedID = reservation.id
        do {
            let timeline = try await adapter.createTimeline(id: reservation.id, title: title)
            projectedID = timeline.id
            _ = try await registry.replaceTimeline(timeline)
            advertise(timeline, false)
            return Self.status(timeline)
        } catch {
            if projectedID != reservation.id { await adapter.removeTimeline(id: projectedID) }
            await adapter.removeTimeline(id: reservation.id)
            await registry.removeRuntimeTimeline(id: reservation.id)
            throw error
        }
    }
    func list() async throws -> [TimelineStatus] {
        guard !isClosed() else { throw NodeRuntimeError.notRunning }
        return await registry.listTimelines().map(Self.status)
    }
    func rename(_ request: TimelineUpdateRequest) async throws -> TimelineStatus {
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard let adapter = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let previous = await registry.timeline(id: request.timelineID)?.timeline
        let timeline = try await adapter.renameTimeline(id: request.timelineID, title: request.title)
        do { _ = try await registry.replaceTimeline(timeline); advertise(timeline, true); return Self.status(timeline) }
        catch { if let previous { _ = try? await adapter.renameTimeline(id: previous.id, title: previous.title) }; throw error }
    }
    static func status(_ timeline: AscendantRuntimeTimeline) -> TimelineStatus { .init(timelineID: timeline.id, title: timeline.title, attachedWorkspaceIDs: timeline.attachedWorkspaceIDs, isArchived: timeline.isArchived, isPrivate: timeline.isPrivate) }
}

/// The narrow network-discovery capability consumed by Workspace domain logic.
/// Tests can supply a stub without constructing Axoloty or a broker connection.
@MainActor
protocol WorkspaceDiscovery: Sendable {
    func discover(timeout: Duration) async
    func objects() async -> [NetworkCatalogEntry]
    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus
}

@MainActor
final class AxolotyWorkspaceDiscovery: WorkspaceDiscovery {
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let communication: CommunicationManager

    init(catalog: NetworkCatalog, subscription: GnosticSubscription, communication: CommunicationManager) {
        self.catalog = catalog
        self.subscription = subscription
        self.communication = communication
    }

    func discover(timeout: Duration) async {
        await subscription.discover(using: communication, timeout: timeout)
    }

    func objects() async -> [NetworkCatalogEntry] { await catalog.networkObjects() }

    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus {
        await catalog.workspaceAttachmentStatus(id: id)
    }
}

@MainActor
public final class WorkspaceService {
    private let plan: NodeLaunchPlan
    private let registry: NodeRegistry
    private let discovery: any WorkspaceDiscovery
    private let localWorkspaces: [UUID: any Workspace]
    private let adapter: @MainActor (UUID) -> (any AscendantRuntimeAdapter)?
    private let isRunning: @MainActor () -> Bool
    private let readvertiseTimeline: @MainActor (AscendantRuntimeTimeline) -> Void
    private var references: [UUID: WorkspaceReference]

    init(
        plan: NodeLaunchPlan,
        registry: NodeRegistry,
        discovery: any WorkspaceDiscovery,
        localWorkspaces: [UUID: any Workspace],
        references: [UUID: WorkspaceReference],
        isRunning: @escaping @MainActor () -> Bool,
        adapter: @escaping @MainActor (UUID) -> (any AscendantRuntimeAdapter)?,
        readvertiseTimeline: @escaping @MainActor (AscendantRuntimeTimeline) -> Void
    ) {
        self.plan = plan; self.registry = registry; self.discovery = discovery
        self.localWorkspaces = localWorkspaces; self.references = references
        self.isRunning = isRunning; self.adapter = adapter
        self.readvertiseTimeline = readvertiseTimeline
    }

    func reference(id: UUID) async -> WorkspaceReference? {
        guard let record = await registry.workspace(id: id), let reference = references[id],
              record.isAvailable || reference.tools.isEmpty,
              reference.uri.description == record.uri else { return nil }
        return reference
    }

    func localReferences() -> [WorkspaceReference] {
        references.values.filter { reference in plan.workspaces.contains { $0.id == reference.id } }
    }

    func executeLocalTool(workspaceID: UUID, toolID: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        guard let workspace = localWorkspaces[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
        return try await workspace.executeTool(id: toolID, parameters: arguments)
    }

    func listAttachable() async -> [WorkspaceListing] {
        var listings = Dictionary(uniqueKeysWithValues: plan.workspaces.map {
            ($0.id, WorkspaceListing(id: $0.id, name: $0.name, isAvailable: true))
        })
        for entry in await discovery.objects() where entry.objectType == GnosticObjectType.workspace
            && entry.workspace?.isAvailable == true && listings[entry.objectID] == nil {
            guard case .available = await discovery.attachmentStatus(id: entry.objectID) else { continue }
            listings[entry.objectID] = WorkspaceListing(id: entry.objectID, name: entry.name, isAvailable: true)
        }
        return listings.values.sorted { ($0.id.uuidString, $0.name) < ($1.id.uuidString, $1.name) }
    }

    func attach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let runtime = try await operatingAdapter(for: request.timelineID)
        let reference: WorkspaceReference
        if localWorkspaces[request.workspaceID] != nil, let local = references[request.workspaceID] {
            reference = local
        } else {
            reference = try await resolveNetworkWorkspace(workspaceID: request.workspaceID)
        }
        try await runtime.attachWorkspace(reference, to: request.timelineID)
        if let timeline = try await runtime.timelines().first(where: { $0.id == request.timelineID }) {
            do {
                _ = try await registry.replaceTimeline(timeline, projecting: { [readvertiseTimeline] record in
                    readvertiseTimeline(record.timeline)
                })
            }
            catch { try? await runtime.detachWorkspace(request.workspaceID, from: request.timelineID); throw error }
        }
        return true
    }

    func detach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let runtime = try await operatingAdapter(for: request.timelineID)
        let prior = references[request.workspaceID]
        try await runtime.detachWorkspace(request.workspaceID, from: request.timelineID)
        if let timeline = try await runtime.timelines().first(where: { $0.id == request.timelineID }) {
            do {
                _ = try await registry.replaceTimeline(timeline, projecting: { [readvertiseTimeline] record in
                    readvertiseTimeline(record.timeline)
                })
            }
            catch { if let prior { try? await runtime.attachWorkspace(prior, to: request.timelineID) }; throw error }
        }
        return true
    }

    func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> WorkspaceReference {
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        await discovery.discover(timeout: timeout)
        let status = await discovery.attachmentStatus(id: workspaceID)
        guard case let .available(_, uri) = status,
              let descriptor = await discovery.objects().first(where: { $0.objectID == workspaceID && $0.workspace?.uri == uri })?.workspace,
              let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        if let configured = await registry.workspace(id: workspaceID), configured.uri != uri {
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        try await installResolved(reference, workspaceID: workspaceID)
        return reference
    }

    func networkAttachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await discovery.attachmentStatus(id: workspaceID)
    }

    func refreshUnresolved() async {
        await discovery.discover(timeout: .milliseconds(250))
        for workspaceID in await registry.unresolvedWorkspaceIDs() {
            _ = try? await resolveAvailableNetworkWorkspace(workspaceID)
        }
    }

    @discardableResult
    func resolveAvailableNetworkWorkspace(_ workspaceID: UUID) async throws -> WorkspaceReference? {
        guard let expectedURI = await registry.workspace(id: workspaceID)?.uri else { return nil }
        let status = await discovery.attachmentStatus(id: workspaceID)
        guard case let .available(_, uri) = status, uri == expectedURI,
              let descriptor = await discovery.objects().first(where: { $0.objectID == workspaceID && $0.workspace?.uri == uri })?.workspace,
              let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else { return nil }
        try await installResolved(reference, workspaceID: workspaceID)
        return reference
    }

    private func operatingAdapter(for timelineID: UUID) async throws -> any AscendantRuntimeAdapter {
        let ascendantID = try await registry.requireOperatingAscendant(for: timelineID)
        guard let runtime = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        return runtime
    }

    private func installResolved(_ reference: WorkspaceReference, workspaceID: UUID) async throws {
        let attached = plan.timelines.filter { $0.attachments.contains { $0.workspaceID == workspaceID && $0.scope == .network } }
        for ascendantID in Set(attached.compactMap(\.operatingAscendantID)) {
            guard let runtime = adapter(ascendantID) else { continue }
            for timeline in attached where timeline.operatingAscendantID == ascendantID {
                try await runtime.attachWorkspace(reference, to: timeline.id)
            }
        }
        guard try await registry.resolveLazyWorkspace(id: workspaceID, uri: reference.uri.description, toolIDs: reference.tools.map(\.toolID)) else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        references[workspaceID] = reference
    }
}

@MainActor
final class NodeProjectionRelay {
    private weak var transport: NodeTransport?

    func bind(_ transport: NodeTransport) { self.transport = transport }

    func projectTimeline(_ timeline: AscendantRuntimeTimeline, replacing: Bool) {
        transport?.projectTimeline(timeline, replacing: replacing)
    }
}

/// Broker-facing forwarding boundary. It is intentionally unable to access a
/// registry, adapter, or PositronicKit object directly.
@MainActor
public final class NodeTransport {
    typealias Chat = @MainActor (AgentChatRequest) async throws -> AgentChatResult
    typealias TimelineStatusLookup = @MainActor (UUID) async throws -> TimelineStatus
    typealias AscendantSelection = @MainActor (UUID?) throws -> UUID
    typealias TimelineCreation = @MainActor (String, UUID) async throws -> TimelineStatus
    typealias TimelineList = @MainActor () async throws -> [TimelineStatus]
    typealias TimelineRename = @MainActor (TimelineUpdateRequest) async throws -> TimelineStatus
    typealias WorkspaceList = @MainActor () async -> [WorkspaceListing]
    typealias WorkspaceMutation = @MainActor (WorkspaceOpsRequest) async throws -> Bool

    private let isAvailable: @MainActor () -> Bool
    private let chatOperation: Chat
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
        workspaceReferences: @escaping @MainActor () async -> [WorkspaceReference] = { [] },
        localWorkspaces: [UUID: any Workspace] = [:],
        isAvailable: @escaping @MainActor () -> Bool,
        chat: @escaping Chat,
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
        self.workspaceReferences = workspaceReferences
        workspaceProvider = localWorkspaces.isEmpty ? nil : MultiplexedWorkspaceProvider(workspaces: localWorkspaces) {
            await isAvailable()
        }
        self.isAvailable = isAvailable
        chatOperation = chat
        timelineStatusOperation = timelineStatus
        selectAscendantOperation = selectAscendant
        createTimelineOperation = createTimeline
        listTimelinesOperation = listTimelines
        renameTimelineOperation = renameTimeline
        listWorkspacesOperation = listWorkspaces
        attachWorkspaceOperation = attachWorkspace
        detachWorkspaceOperation = detachWorkspace
    }

    public func chat(_ request: AgentChatRequest) async throws -> AgentChatResult {
        try await chatOperation(request)
    }

    func registerOperations(
        turnUpdates: AscendantTurnUpdateStore,
        permissionCoordinator: AscendantPermissionCoordinator
    ) async throws {
        guard let communication else { throw NodeRuntimeError.notRunning }
        if let workspaceProvider {
            registrations.append(try await workspaceProvider.register(on: communication))
        }
        let agentChat = AgentChatProvider(
            execute: { [weak self] request in
                guard let self, await self.isAvailable() else { throw NodeRuntimeError.notRunning }
                return try await self.chat(request)
            },
            replayStore: turnUpdates,
            isAvailable: { [weak self] in await self?.isAvailable() == true }
        )
        registrations.append(try await agentChat.register(on: communication, context: communication.identity))
        registrations.append(try await agentChat.registerReplay(on: communication, context: communication.identity))

        let permission = AgentPermissionProvider(coordinator: permissionCoordinator)
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

    private func discoverableObjects() async -> [CoatyObject] {
        var objects: [CoatyObject] = ascendantIdentities().map { GnosticAgentObject(identity: $0) }
        if let registry {
            objects += await registry.listTimelines().map(GnosticTimelineObject.init)
        }
        objects += await workspaceReferences().map(GnosticWorkspaceObject.init)
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
