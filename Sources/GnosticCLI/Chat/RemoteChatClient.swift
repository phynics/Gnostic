// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared
import PositronicKit

/// Failures produced by the remote chat client.
public enum RemoteChatClientError: Error, Sendable, LocalizedError {
    case brokerUnreachable(String)
    case noServedAgent
    case workspaceUnavailable
    case workspaceAmbiguous
    case timelineNotAttached
    case approvalRequired
    case toolNotAdvertised
    case invalidWorkspaceURI
    case ambiguousAscendant
    case ascendantUnavailable(UUID)
    case providerUnavailable(String)
    case timelineUnavailable(UUID)
    case timelineAmbiguous(UUID)
    case providerMismatch

    public var errorDescription: String? {
        switch self {
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case .noServedAgent: "No served agent was discovered. Start `gnostic serve` first."
        case .workspaceUnavailable: "The workspace is not currently available."
        case .workspaceAmbiguous: "The workspace is advertised by more than one provider."
        case .timelineNotAttached: "The workspace is not attached to the requested timeline."
        case .approvalRequired: "This tool requires explicit approval."
        case .toolNotAdvertised: "The requested tool is not advertised by the workspace."
        case .invalidWorkspaceURI: "The workspace advertised an invalid URI."
        case .ambiguousAscendant: "More than one Ascendant was discovered; select one explicitly."
        case let .ascendantUnavailable(id): "Ascendant \(id.uuidString.lowercased()) was not discovered."
        case let .providerUnavailable(id): "Provider \(id.lowercased()) was not discovered."
        case let .timelineUnavailable(id): "Timeline \(id.uuidString.lowercased()) was not discovered."
        case let .timelineAmbiguous(id): "Timeline \(id.uuidString.lowercased()) is advertised by more than one Node."
        case .providerMismatch: "The response came from a different provider than the addressed Node."
        }
    }

    /// Stable machine-readable code for JSON-RPC clients.
    public var gnosticCode: String {
        switch self {
        case .brokerUnreachable: "brokerUnreachable"
        case .noServedAgent: "noServedAgent"
        case .workspaceUnavailable: "workspaceUnavailable"
        case .workspaceAmbiguous: "workspaceAmbiguous"
        case .timelineNotAttached: "timelineNotAttached"
        case .approvalRequired: "approvalRequired"
        case .toolNotAdvertised: "toolNotAdvertised"
        case .invalidWorkspaceURI: "invalidWorkspaceURI"
        case .ambiguousAscendant: "ambiguousAscendant"
        case .ascendantUnavailable: "ascendantUnavailable"
        case .providerUnavailable: "providerUnavailable"
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .providerMismatch: "providerMismatch"
        }
    }
}

/// A pure-Axoloty client for `gnostic serve`'s network operations.
///
/// Mirrors `AxolotyWorkspace`: every interaction is a unary Call/Return over the
/// Axoloty stack (`communication.call(operation:...)`) — no raw MQTT, no local
/// PositronicKit runtime.
@MainActor
public final class RemoteChatClient: Sendable {
    public struct DiscoveredAscendant: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let timelineID: UUID
        public let providerID: String

        public init(id: UUID, name: String, timelineID: UUID, providerID: String) {
            self.id = id
            self.name = name
            self.timelineID = timelineID
            self.providerID = providerID
        }
    }
    public let host: String
    public let port: Int
    public let namespace: String
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let timeout: Duration
    private let promptTimeout: Duration
    private var stateTask: Task<Void, Never>?
    private var connectionLost = false

    /// Creates a client bound to a broker namespace.
    public init(
        host: String,
        port: Int,
        namespace: String,
        timeout: Duration = .seconds(5),
        promptTimeout: Duration? = nil
    ) throws {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.timeout = timeout
        self.promptTimeout = promptTimeout ?? timeout
        manager = try CommunicationManager(
            identity: Identity(name: "gnostic-chat-client"),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: host,
                    port: UInt16(port),
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
        catalog = NetworkCatalog()
        subscription = GnosticSubscription(catalog: catalog, communicationManager: manager)
    }

    /// Connects and subscribes to Gnostic object advertisements.
    public func connect() async throws {
        let stream = await manager.observeCommunicationStateStream()
        var iterator = stream.makeAsyncIterator()
        try manager.start()
        while let state = await iterator.next() {
            if state == .online {
                try await subscription.start()
                connectionLost = false
                stateTask?.cancel()
                stateTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let states = await self.manager.observeCommunicationStateStream()
                    for await state in states {
                        if state != .online { self.connectionLost = true }
                    }
                }
                return
            }
        }
        throw RemoteChatClientError.brokerUnreachable("timed out connecting")
    }

    /// Stops the client's manager and subscriptions.
    public func stop() {
        stateTask?.cancel()
        stateTask = nil
        subscription.stop()
        manager.stop()
    }

    /// Whether the underlying broker connection has been lost since connect.
    public var hasLostConnection: Bool { connectionLost }

    /// Refreshes the catalog using Axoloty's active discover request.
    public func refreshCatalog() async {
        await subscription.discover(using: manager, timeout: timeout)
    }

    /// Returns provider-scoped discovered objects from the current catalog.
    public func listNetworkObjects() async -> [NetworkCatalogEntry] {
        await refreshCatalog()
        return await catalog.networkObjects()
    }

    public func discoverAscendants() async -> [DiscoveredAscendant] {
        await refreshCatalog()
        return await catalog.networkObjects()
            .filter { $0.objectType == GnosticObjectType.agent }
            .compactMap { entry in
                guard case let .string(raw) = entry.knownProperties["privateTimelineID"],
                      let timelineID = UUID(uuidString: raw) else { return nil }
                return DiscoveredAscendant(id: entry.objectID, name: entry.name, timelineID: timelineID, providerID: entry.providerID)
            }
            .sorted { ($0.id.uuidString, $0.providerID) < ($1.id.uuidString, $1.providerID) }
    }

    /// Invokes an advertised workspace tool through the existing Axoloty connection.
    public func invokeWorkspace(
        workspaceID: UUID,
        providerID: String,
        timelineID: UUID,
        toolID: String,
        parameters: [String: AnyCodable],
        approved: Bool
    ) async throws -> ToolResult {
        await refreshCatalog()
        guard let entry = await catalog.object(id: workspaceID, providerID: providerID),
              let descriptor = entry.workspace else {
            throw RemoteChatClientError.workspaceUnavailable
        }
        guard case let .available(currentProvider, _) = await catalog.workspaceAttachmentStatus(id: workspaceID) else {
            let status = await catalog.workspaceAttachmentStatus(id: workspaceID)
            if case .ambiguous = status { throw RemoteChatClientError.workspaceAmbiguous }
            throw RemoteChatClientError.workspaceUnavailable
        }
        guard currentProvider == providerID, descriptor.isAvailable else {
            throw RemoteChatClientError.workspaceUnavailable
        }
        let timeline = try await timelineStatus(timelineID: timelineID, providerID: providerID)
        guard timeline.attachedWorkspaceIDs.contains(workspaceID) else {
            throw RemoteChatClientError.timelineNotAttached
        }
        guard let tool = descriptor.tools.first(where: { $0.id == toolID }) else {
            throw RemoteChatClientError.toolNotAdvertised
        }
        guard !tool.requiresPermission || approved else {
            throw RemoteChatClientError.approvalRequired
        }
        guard let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            throw RemoteChatClientError.invalidWorkspaceURI
        }
        let workspace = AxolotyWorkspace(
            reference: reference,
            catalog: catalog,
            communication: manager,
            timeout: timeout
        )
        return try await workspace.executeTool(id: toolID, parameters: parameters)
    }

    /// Runs one chat turn over `agent.chat`.
    public func chat(message: String, timelineID: UUID) async throws -> String {
        try await chat(message: message, timelineID: timelineID, clientTurnID: nil).text
    }

    /// Runs an identified chat turn and returns replay metadata. Supplying a
    /// stable id enables serve-lifetime deduplication; `nil` preserves the
    /// legacy non-idempotent request shape.
    public func chat(
        message: String,
        timelineID: UUID,
        clientTurnID: String?,
        providerID: String? = nil
    ) async throws -> AgentChatResult {
        let payload = try JSONEncoder().encode(
            AgentChatRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID)
        )
        let response = try await call(
            operation: AgentChatProvider.chatOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: try await resolvedProviderID(providerID, forTimeline: timelineID),
            timeout: promptTimeout
        )
        return try JSONDecoder().decode(AgentChatResult.self, from: Data(response.result.utf8))
    }

    /// Reads bounded identified-turn updates retained by the serve runtime.
    /// ACP adapters use this operation to replay updates after a stdio or
    /// broker reconnect without re-running the Timeline turn.
    public func replay(
        timelineID: UUID,
        clientTurnID: String,
        message: String? = nil,
        afterSequence: Int = 0,
        providerID: String? = nil
    ) async throws -> AscendantTurnReplay {
        let payload = try JSONEncoder().encode(
            AgentChatReplayRequest(timelineID: timelineID, clientTurnID: clientTurnID, message: message, afterSequence: afterSequence)
        )
        let response = try await call(
            operation: AgentChatProvider.replayOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: try await resolvedProviderID(providerID, forTimeline: timelineID),
            timeout: timeout
        )
        return try JSONDecoder().decode(AscendantTurnReplay.self, from: Data(response.result.utf8))
    }

    public func observeTurnUpdates(providerID: String? = nil) async throws -> AsyncStream<AscendantTurnUpdateStore.Event> {
        let snapshots = try await manager.observeChannelStream(channelId: AgentChatProvider.updateChannel)
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in snapshots {
                    if let providerID,
                       snapshot.sourceId?.lowercased() != providerID.lowercased() { continue }
                    guard let raw = snapshot.privateData,
                          let event = try? JSONDecoder().decode(
                            AscendantTurnUpdateStore.Event.self,
                            from: Data(raw.utf8)
                          ) else { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func respondToPermission(_ permission: AgentPermissionResponse, providerID: String? = nil) async throws {
        manager.publishChannel(try AgentPermissionProvider.responseEvent(permission.targeted(to: providerID)))
    }

    /// Reads the served timeline's attachment state.
    public func timelineStatus(timelineID: UUID, providerID: String? = nil) async throws -> TimelineStatus {
        let payload = try JSONEncoder().encode(TimelineStatusRequest(timelineID: timelineID))
        let response = try await call(
            operation: TimelineStatusProvider.statusOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: try await resolvedProviderID(providerID, forTimeline: timelineID),
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
    }

    /// Creates a new timeline on the serve and returns its status.
    public func createTimeline(title: String, ascendantID: UUID? = nil, providerID: String? = nil) async throws -> TimelineStatus {
        let payload = try JSONEncoder().encode(TimelineCreateRequest(title: title, ascendantID: ascendantID))
        let targetProvider: String?
        if let providerID {
            targetProvider = providerID
        } else if let ascendantID {
            targetProvider = try await selectAscendant(id: ascendantID).providerID
        } else {
            targetProvider = try await selectAscendant(id: nil).providerID
        }
        let response = try await call(
            operation: TimelineManagementProvider.createOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: targetProvider,
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
    }

    /// Lists every timeline the serve manages.
    public func listTimelines(providerID: String? = nil) async throws -> [TimelineStatus] {
        let targetProvider: String?
        if let providerID { targetProvider = providerID } else { targetProvider = try await singleProviderID() }
        let response = try await call(
            operation: TimelineManagementProvider.listOperation,
            providerID: targetProvider,
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineListResult.self, from: Data(response.result.utf8)).timelines
    }

    /// Renames a timeline and returns its updated status.
    public func updateTimeline(timelineID: UUID, title: String, providerID: String? = nil) async throws -> TimelineStatus {
        let payload = try JSONEncoder().encode(TimelineUpdateRequest(timelineID: timelineID, title: title))
        let response = try await call(
            operation: TimelineManagementProvider.updateOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: try await resolvedProviderID(providerID, forTimeline: timelineID),
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
    }

    /// Lists attachable workspaces.
    public func listWorkspaces(providerID: String? = nil) async throws -> [WorkspaceListing] {
        let targetProvider: String?
        if let providerID { targetProvider = providerID } else { targetProvider = try await singleProviderID() }
        let response = try await call(
            operation: WorkspaceOpsProvider.listOperation,
            providerID: targetProvider,
            timeout: timeout
        )
        return try JSONDecoder().decode(WorkspaceListResult.self, from: Data(response.result.utf8)).workspaces
    }

    /// Attaches a workspace to a timeline.
    public func attach(workspaceID: UUID, timelineID: UUID, providerID: String? = nil) async throws -> Bool {
        try await mutate(operation: WorkspaceOpsProvider.attachOperation, workspaceID: workspaceID, timelineID: timelineID, providerID: providerID)
    }

    /// Detaches a workspace from a timeline.
    public func detach(workspaceID: UUID, timelineID: UUID, providerID: String? = nil) async throws -> Bool {
        try await mutate(operation: WorkspaceOpsProvider.detachOperation, workspaceID: workspaceID, timelineID: timelineID, providerID: providerID)
    }

    private func mutate(operation: String, workspaceID: UUID, timelineID: UUID, providerID: String? = nil) async throws -> Bool {
        let payload = try JSONEncoder().encode(WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: timelineID))
        let response = try await call(
            operation: operation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: try await resolvedProviderID(providerID, forTimeline: timelineID),
            timeout: timeout
        )
        return response.result == "true"
    }

    public func discoverServedTimeline(ascendantID: UUID? = nil) async throws -> UUID {
        try await selectAscendant(id: ascendantID).timelineID
    }

    public func selectAscendant(id ascendantID: UUID? = nil, providerID: String? = nil) async throws -> DiscoveredAscendant {
        let candidates = await discoverAscendants()
        if ascendantID != nil || providerID != nil {
            let matches = candidates.filter {
                (ascendantID == nil || $0.id == ascendantID)
                    && (providerID == nil || $0.providerID.lowercased() == providerID?.lowercased())
            }
            guard let candidate = matches.first else {
                if let ascendantID { throw RemoteChatClientError.ascendantUnavailable(ascendantID) }
                throw RemoteChatClientError.providerUnavailable(providerID ?? "")
            }
            guard matches.count == 1 else { throw RemoteChatClientError.ambiguousAscendant }
            return candidate
        }
        guard candidates.count == 1 else {
            if candidates.isEmpty { throw RemoteChatClientError.noServedAgent }
            throw RemoteChatClientError.ambiguousAscendant
        }
        return candidates[0]
    }

    private func discoveredProviderID(forTimeline timelineID: UUID) async throws -> String {
        await refreshCatalog()
        let providers = Set(await catalog.networkObjects().compactMap {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID ? $0.providerID : nil
        })
        guard let provider = providers.first else { throw RemoteChatClientError.timelineUnavailable(timelineID) }
        guard providers.count == 1 else { throw RemoteChatClientError.timelineAmbiguous(timelineID) }
        return provider
    }

    private func resolvedProviderID(_ explicit: String?, forTimeline timelineID: UUID) async throws -> String {
        if let explicit { return explicit }
        return try await discoveredProviderID(forTimeline: timelineID)
    }

    private func singleProviderID() async throws -> String {
        await refreshCatalog()
        let entries = await catalog.networkObjects()
        let providers = Set(entries.compactMap {
            $0.objectType == GnosticObjectType.agent || $0.objectType == GnosticObjectType.timeline ? $0.providerID : nil
        })
        guard let provider = providers.first else { throw RemoteChatClientError.noServedAgent }
        guard providers.count == 1 else { throw RemoteChatClientError.ambiguousAscendant }
        return provider
    }

    private func call(operation: String, parameters: String? = nil, providerID: String?, timeout: Duration) async throws -> UnaryCallResult {
        let response = try await manager.call(
            operation: operation,
            parameters: parameters,
            context: providerID.map(Self.providerContext),
            timeout: timeout
        )
        if let providerID, response.sourceId?.lowercased() != providerID.lowercased() {
            throw RemoteChatClientError.providerMismatch
        }
        return response
    }

    private static func providerContext(_ providerID: String) -> ObjectFilter {
        ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        ))
    }
}

/// The long-lived bridge client name. The chat client remains source-compatible
/// for the interactive command while both surfaces share one Axoloty connection.
public typealias GnosticRemoteClient = RemoteChatClient
