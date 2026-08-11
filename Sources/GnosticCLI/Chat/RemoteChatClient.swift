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
    public let host: String
    public let port: Int
    public let namespace: String
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let timeout: Duration
    private var stateTask: Task<Void, Never>?
    private var connectionLost = false

    /// Creates a client bound to a broker namespace.
    public init(host: String, port: Int, namespace: String, timeout: Duration = .seconds(5)) throws {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.timeout = timeout
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
        let timeline = try await timelineStatus(timelineID: timelineID)
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

    /// Discovers the served Agent's timeline ID from advertised objects.
    public func discoverServedTimeline() async throws -> UUID {
        await subscription.discover(using: manager, timeout: timeout)
        let agents = await catalog.networkObjects().filter { $0.objectType == GnosticObjectType.agent }
        if let timeline = agents.lazy.compactMap({ entry -> UUID? in
            guard case let .string(raw) = entry.knownProperties["privateTimelineID"],
                  let id = UUID(uuidString: raw) else { return nil }
            return id
        }).first {
            return timeline
        }
        throw RemoteChatClientError.noServedAgent
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
        clientTurnID: String?
    ) async throws -> AgentChatResult {
        let payload = try JSONEncoder().encode(
            AgentChatRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID)
        )
        let response = try await manager.call(
            operation: AgentChatProvider.chatOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: timeout
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
        afterSequence: Int = 0
    ) async throws -> AscendantTurnReplay {
        let payload = try JSONEncoder().encode(
            AgentChatReplayRequest(timelineID: timelineID, clientTurnID: clientTurnID, message: message, afterSequence: afterSequence)
        )
        let response = try await manager.call(
            operation: AgentChatProvider.replayOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: timeout
        )
        return try JSONDecoder().decode(AscendantTurnReplay.self, from: Data(response.result.utf8))
    }

    /// Reads the served timeline's attachment state.
    public func timelineStatus(timelineID: UUID) async throws -> TimelineStatus {
        let payload = try JSONEncoder().encode(TimelineStatusRequest(timelineID: timelineID))
        let response = try await manager.call(
            operation: TimelineStatusProvider.statusOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
    }

    /// Creates a new timeline on the serve and returns its status.
    public func createTimeline(title: String) async throws -> TimelineStatus {
        let payload = try JSONEncoder().encode(TimelineCreateRequest(title: title))
        let response = try await manager.call(
            operation: TimelineManagementProvider.createOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
    }

    /// Lists every timeline the serve manages.
    public func listTimelines() async throws -> [TimelineStatus] {
        let response = try await manager.call(
            operation: TimelineManagementProvider.listOperation,
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineListResult.self, from: Data(response.result.utf8)).timelines
    }

    /// Renames a timeline and returns its updated status.
    public func updateTimeline(timelineID: UUID, title: String) async throws -> TimelineStatus {
        let payload = try JSONEncoder().encode(TimelineUpdateRequest(timelineID: timelineID, title: title))
        let response = try await manager.call(
            operation: TimelineManagementProvider.updateOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: timeout
        )
        return try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
    }

    /// Lists attachable workspaces.
    public func listWorkspaces() async throws -> [WorkspaceListing] {
        let response = try await manager.call(
            operation: WorkspaceOpsProvider.listOperation,
            timeout: timeout
        )
        return try JSONDecoder().decode(WorkspaceListResult.self, from: Data(response.result.utf8)).workspaces
    }

    /// Attaches a workspace to a timeline.
    public func attach(workspaceID: UUID, timelineID: UUID) async throws -> Bool {
        try await mutate(operation: WorkspaceOpsProvider.attachOperation, workspaceID: workspaceID, timelineID: timelineID)
    }

    /// Detaches a workspace from a timeline.
    public func detach(workspaceID: UUID, timelineID: UUID) async throws -> Bool {
        try await mutate(operation: WorkspaceOpsProvider.detachOperation, workspaceID: workspaceID, timelineID: timelineID)
    }

    private func mutate(operation: String, workspaceID: UUID, timelineID: UUID) async throws -> Bool {
        let payload = try JSONEncoder().encode(WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: timelineID))
        let response = try await manager.call(
            operation: operation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: timeout
        )
        return response.result == "true"
    }
}

/// The long-lived bridge client name. The chat client remains source-compatible
/// for the interactive command while both surfaces share one Axoloty connection.
public typealias GnosticRemoteClient = RemoteChatClient
