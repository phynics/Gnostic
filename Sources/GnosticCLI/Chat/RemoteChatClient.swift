// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared

/// Failures produced by the remote chat client.
public enum RemoteChatClientError: Error, Sendable, LocalizedError {
    case brokerUnreachable(String)
    case noServedAgent

    public var errorDescription: String? {
        switch self {
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case .noServedAgent: "No served agent was discovered. Start `gnostic serve` first."
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
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let namespace: String
    private let timeout: Duration

    /// Creates a client bound to a broker namespace.
    public init(host: String, port: Int, namespace: String, timeout: Duration = .seconds(5)) throws {
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
                return
            }
        }
        throw RemoteChatClientError.brokerUnreachable("timed out connecting")
    }

    /// Stops the client's manager and subscriptions.
    public func stop() {
        subscription.stop()
        manager.stop()
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
        let payload = try JSONEncoder().encode(AgentChatRequest(message: message, timelineID: timelineID))
        let response = try await manager.call(
            operation: AgentChatProvider.chatOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: timeout
        )
        return try JSONDecoder().decode(AgentChatResult.self, from: Data(response.result.utf8)).text
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
