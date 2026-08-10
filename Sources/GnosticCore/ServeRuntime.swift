// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import Logging
import PKShared
import PositronicKit

/// Failures produced by the serve runtime.
public enum ServeRuntimeError: Error, Sendable, LocalizedError {
    case containerFailed(String)
    case timelineCreationFailed

    public var errorDescription: String? {
        switch self {
        case let .containerFailed(detail): "Could not start the serve container: \(detail)"
        case .timelineCreationFailed: "Could not create the served timeline."
        }
    }
}

/// Owns the serve process: the PositronicKit runtime, the Axoloty container that
/// advertises canonical objects, and the unary operations remote clients use.
///
/// This is the composition root for GNO-serve. It wires the existing pieces
/// (OrchestrationProjector, DiscoveredWorkspaceAttachmentService, the provider
/// wire adapters, and PositronicKit) behind the serve command.
@MainActor
public final class ServeRuntime {
    public let host: String
    public let port: Int
    public let namespace: String
    public let approveMode: ServeApproveMode

    private let container: Container
    private let communication: CommunicationManager
    private let lifecycle: ObjectLifecycleController
    private let kit: PositronicKit
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let attachmentService: DiscoveredWorkspaceAttachmentService
    private let projector: OrchestrationProjector
    private let agentChat: AgentChatProvider
    private let timelineStatus: TimelineStatusProvider
    private let timelineManagement: TimelineManagementProvider
    private let workspaceOps: WorkspaceOpsProvider

    private let timelineID: UUID
    private let logger: Logger
    private var registrations: [CallHandlerRegistration] = []
    private var discoverResponder: DiscoverResponderRegistration?
    private var advertisedAgent: AgentInstance?
    private var advertisedWorkspaces: [WorkspaceReference] = []

    /// Creates the runtime.
    public init(
        host: String,
        port: Int,
        namespace: String,
        approveMode: ServeApproveMode = .auto,
        languageModel: any LanguageModel = UnconfiguredLLMService(),
        logger: Logger = ServeLogging.makeLogger()
    ) async throws {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.approveMode = approveMode
        self.logger = logger

        // Provider container: advertises objects and hosts unary handlers.
        container = try Container.resolve(
            components: Components(
                controllers: ["ObjectLifecycleController": ObjectLifecycleController.self],
                objectTypes: [GnosticAgentObject.self, GnosticTimelineObject.self, GnosticWorkspaceObject.self]
            ),
            configuration: Configuration(
                common: CommonOptions(agentIdentity: ["name": "gnostic-serve"]),
                communication: CommunicationOptions(
                    namespace: namespace,
                    shouldEnableCrossNamespacing: false,
                    mqttClientOptions: MQTTClientOptions(
                        host: host,
                        port: UInt16(port),
                        shouldTryMDNSDiscovery: false,
                        autoReconnect: false
                    ),
                    shouldAutoStart: false
                )
            )
        )
        communication = try container.communicationManager.serveUnwrap()
        lifecycle = try container.getController(name: "ObjectLifecycleController").serveUnwrap()

        // PositronicKit runtime: owns the timeline + chat turns. The command
        // injects the configured model; tests/fixture use the unconfigured
        // credential-free service.
        kit = PositronicKit(languageModel: languageModel)
        let timeline = try await kit.timelineManager.createTimeline()
        timelineID = timeline.id

        // Consumer side: a catalog of advertised objects (for workspace.list and
        // attach) fed by a subscription on the same manager that advertises, so
        // the serve observes its own canonical objects (fixture pattern).
        catalog = NetworkCatalog()
        subscription = GnosticSubscription(catalog: catalog, communicationManager: communication)

        projector = OrchestrationProjector(
            advertise: { [lifecycle] object in
                lifecycle.advertiseDiscoverableObject(object: object)
            },
            readvertise: { [lifecycle] object in
                lifecycle.advertiseDiscoverableObject(object: object)
            }
        )

        attachmentService = DiscoveredWorkspaceAttachmentService(catalog: catalog,
            timelineManager: kit.timelineManager
        ) { _ in }

        // Wire the unary operations, each emitting started/succeeded/denied/failed
        // trace records for operator traceability.
        agentChat = AgentChatProvider { [kit, logger] request in
            ServeTrace.operationStarted(logger: logger, operation: AgentChatProvider.chatOperation, timelineID: request.timelineID, workspaceID: nil)
            do {
                let text = try await ServeRuntime.runTurn(kit: kit, timelineID: request.timelineID, message: request.message)
                ServeTrace.operationSucceeded(logger: logger, operation: AgentChatProvider.chatOperation, timelineID: request.timelineID, workspaceID: nil)
                return AgentChatResult(text: text)
            } catch {
                ServeTrace.operationFailed(logger: logger, operation: AgentChatProvider.chatOperation, timelineID: request.timelineID, workspaceID: nil, error: String(describing: error))
                throw error
            }
        }
        timelineStatus = TimelineStatusProvider { [kit, logger] request in
            ServeTrace.operationStarted(logger: logger, operation: TimelineStatusProvider.statusOperation, timelineID: request.timelineID, workspaceID: nil)
            do {
                let status = try await ServeRuntime.timelineStatus(kit: kit, timelineID: request.timelineID)
                ServeTrace.operationSucceeded(logger: logger, operation: TimelineStatusProvider.statusOperation, timelineID: request.timelineID, workspaceID: nil)
                return status
            } catch {
                ServeTrace.operationFailed(logger: logger, operation: TimelineStatusProvider.statusOperation, timelineID: request.timelineID, workspaceID: nil, error: String(describing: error))
                throw error
            }
        }
        workspaceOps = WorkspaceOpsProvider(
            list: { [catalog] in await ServeRuntime.attachableWorkspaces(catalog: catalog) },
            attach: { [attachmentService, approveMode, kit, projector, timelineID, logger] request in
                ServeTrace.operationStarted(logger: logger, operation: WorkspaceOpsProvider.attachOperation, timelineID: request.timelineID, workspaceID: request.workspaceID)
                do {
                    if approveMode != .auto {
                        ServeTrace.operationDenied(logger: logger, operation: WorkspaceOpsProvider.attachOperation, timelineID: request.timelineID, workspaceID: request.workspaceID, reason: "approvalRequired")
                        return false
                    }
                    try await attachmentService.attach(workspaceID: request.workspaceID, to: request.timelineID, approved: true)
                    serveReadvertiseTimeline(kit: kit, projector: projector, timelineID: timelineID)
                    ServeTrace.operationSucceeded(logger: logger, operation: WorkspaceOpsProvider.attachOperation, timelineID: request.timelineID, workspaceID: request.workspaceID)
                    return true
                } catch {
                    ServeTrace.operationFailed(logger: logger, operation: WorkspaceOpsProvider.attachOperation, timelineID: request.timelineID, workspaceID: request.workspaceID, error: String(describing: error))
                    throw error
                }
            },
            detach: { [kit, projector, timelineID, logger] request in
                ServeTrace.operationStarted(logger: logger, operation: WorkspaceOpsProvider.detachOperation, timelineID: request.timelineID, workspaceID: request.workspaceID)
                do {
                    try await kit.timelineManager.detachWorkspace(request.workspaceID, from: request.timelineID)
                    serveReadvertiseTimeline(kit: kit, projector: projector, timelineID: timelineID)
                    ServeTrace.operationSucceeded(logger: logger, operation: WorkspaceOpsProvider.detachOperation, timelineID: request.timelineID, workspaceID: request.workspaceID)
                    return true
                } catch {
                    ServeTrace.operationFailed(logger: logger, operation: WorkspaceOpsProvider.detachOperation, timelineID: request.timelineID, workspaceID: request.workspaceID, error: String(describing: error))
                    throw error
                }
            }
        )

        timelineManagement = TimelineManagementProvider(
            create: { [kit] title in try await ServeRuntime.createTimeline(kit: kit, title: title) },
            list: { [kit] in try await ServeRuntime.listTimelines(kit: kit) },
            update: { [kit] request in try await ServeRuntime.renameTimeline(kit: kit, timelineID: request.timelineID, title: request.title) }
        )
    }

    /// Starts the container, subscribes the observer, and registers all ops.
    public func start() async throws {
        try await container.startAndWaitUntilReady()
        try await subscription.start()
        registrations.append(try await agentChat.register(on: communication))
        registrations.append(try await timelineStatus.register(on: communication))
        registrations += try await timelineManagement.register(on: communication)
        try await workspaceOps.register(on: communication)

        discoverResponder = await communication.registerDiscoverResponder { [weak self] request in
            guard let self else { return }
            try await self.respond(to: request)
        }
        ServeTrace.advertised(logger: logger, objects: 1, timelineID: timelineID)
    }

    /// Advertises the canonical Agent, Timeline, and (optionally) workspaces.
    public func advertise(agent: AgentInstance, workspaces: [WorkspaceReference]) async {
        advertisedAgent = agent
        advertisedWorkspaces = workspaces
        await advertiseAll()
        ServeTrace.advertised(logger: logger, objects: 1 + workspaces.count, timelineID: timelineID)
    }

    /// Registers an externally-owned workspace provider on the serve's single
    /// Axoloty connection. This is used by deterministic integration fixtures
    /// that keep a provider alive while exercising a real bridge subprocess.
    public func register(workspaceProvider: WorkspaceProvider) async throws -> CallHandlerRegistration {
        try await workspaceProvider.register(on: communication)
    }

    /// The id of the served timeline.
    public var servedTimelineID: UUID { timelineID }

    /// The current served timeline state, for advertisement.
    public func currentTimeline() async throws -> Timeline {
        let timelines = try await kit.timelineManager.listTimelines()
        guard let timeline = timelines.first(where: { $0.id == timelineID }) else {
            throw ServeRuntimeError.timelineCreationFailed
        }
        return timeline
    }

    /// Shuts the runtime down cleanly (cancels registrations, stops, deadvertises).
    public func shutdown() {
        ServeTrace.shutdown(logger: logger)
        discoverResponder?.cancel()
        discoverResponder = nil
        registrations.forEach { $0.cancel() }
        subscription.stop()
        container.shutdown()
    }

    private func advertiseAll() async {
        guard let agent = advertisedAgent else { return }
        do {
            let timeline = try await currentTimeline()
            projector.advertise(agent: agent, timeline: timeline, workspaces: advertisedWorkspaces)
        } catch {
            // Advertisement failures are non-fatal; the caller can retry.
        }
    }

    /// Resolves the currently advertised Gnostic objects for a late subscriber.
    private func respond(to request: DiscoverRequest) async throws {
        let requestedTypes = request.snapshot.objectTypes
        let objects = try await discoverableObjects()
        for object in objects {
            guard requestedTypes == nil || requestedTypes?.contains(object.objectType) == true else { continue }
            try request.resolve(object: object)
        }
    }

    /// Builds fresh projections so Resolve responses reflect current timeline
    /// attachment state while preserving the advertised identities.
    private func discoverableObjects() async throws -> [CoatyObject] {
        guard let agent = advertisedAgent else { return [] }
        let timeline = try await currentTimeline()
        return [
            GnosticAgentObject(agent: agent),
            GnosticTimelineObject(timeline: timeline),
        ] + advertisedWorkspaces.map(GnosticWorkspaceObject.init(workspace:))
    }

    // MARK: - Turn logic (mirrors ChatSession; owned by serve)

    private static func runTurn(kit: PositronicKit, timelineID: UUID, message: String) async throws -> String {
        // Include the tools enabled on the served timeline so turns can invoke
        // the attached workspace's tools (echo/list/read) rather than empty.
        let tools = await kit.timelineManager.enabledTools(for: timelineID)
        let stream = try await kit.run(ChatRunRequest(
            timelineID: timelineID,
            message: message,
            tools: tools,
            maxTurns: 5
        ))
        var finalText = ""
        var lastError: String?
        for try await event in stream {
            switch event {
            case .completion(.generationCompleted(let message, _)):
                finalText = message.content
            case .completion(.maxTurnsReached):
                lastError = "The model exhausted its turn budget without a final answer."
            case .error(.error(let message, _)):
                lastError = message
            default:
                break
            }
        }
        if let lastError { throw ServeRuntimeError.containerFailed(lastError) }
        return finalText.isEmpty ? "(empty reply)" : finalText
    }

    private static func createTimeline(kit: PositronicKit, title: String) async throws -> TimelineStatus {
        let timeline = try await kit.timelineManager.createTimeline(title: title)
        return self.mapTimeline(timeline)
    }

    private static func listTimelines(kit: PositronicKit) async throws -> [TimelineStatus] {
        let timelines = try await kit.timelineManager.listTimelines()
        return timelines.map(Self.mapTimeline)
    }

    private static func renameTimeline(kit: PositronicKit, timelineID: UUID, title: String) async throws -> TimelineStatus {
        try await kit.timelineManager.updateTimelineTitle(id: timelineID, title: title)
        let timelines = try await kit.timelineManager.listTimelines()
        guard let timeline = timelines.first(where: { $0.id == timelineID }) else {
            throw ServeRuntimeError.timelineCreationFailed
        }
        return Self.mapTimeline(timeline)
    }

    private static func mapTimeline(_ timeline: Timeline) -> TimelineStatus {
        TimelineStatus(
            timelineID: timeline.id,
            title: timeline.title,
            attachedWorkspaceIDs: timeline.attachedWorkspaceIDs,
            isArchived: timeline.isArchived,
            isPrivate: timeline.isPrivate
        )
    }

    private static func timelineStatus(kit: PositronicKit, timelineID: UUID) async throws -> TimelineStatus {
        let timelines = try await kit.timelineManager.listTimelines()
        guard let timeline = timelines.first(where: { $0.id == timelineID }) else {
            return TimelineStatus(timelineID: timelineID, title: "(unknown)", attachedWorkspaceIDs: [])
        }
        return TimelineStatus(
            timelineID: timeline.id,
            title: timeline.title,
            attachedWorkspaceIDs: timeline.attachedWorkspaceIDs,
            isArchived: timeline.isArchived,
            isPrivate: timeline.isPrivate
        )
    }

    private static func attachableWorkspaces(catalog: NetworkCatalog) async -> [WorkspaceListing] {
        await catalog.networkObjects()
            .filter { $0.objectType == GnosticObjectType.workspace && $0.workspace?.isAvailable == true }
            .map { WorkspaceListing(id: $0.objectID, name: $0.name, isAvailable: true) }
    }
}

/// How the serve process governs approval of mutating workspace operations.
public enum ServeApproveMode: Sendable, Equatable {
    /// Every attach/detach is approved automatically.
    case auto
    /// Mutating operations are denied (interactive approval is future work).
    case deny
}
private extension Optional {
    func serveUnwrap() throws -> Wrapped {
        guard let self else { throw ServeRuntimeError.containerFailed("missing component") }
        return self
    }
}

/// Re-readvertises the served timeline after an attachment change.
/// Sendable-safe: hops to the main actor inside the task.
private func serveReadvertiseTimeline(kit: PositronicKit, projector: OrchestrationProjector, timelineID: UUID) {
    Task { @MainActor in
        let timelines = try? await kit.timelineManager.listTimelines()
        if let timeline = timelines?.first(where: { $0.id == timelineID }) {
            _ = projector.readvertise(timeline: timeline)
        }
    }
}
