// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// The ACP adapter over the public consumer facade.
///
/// Connection, discovery, Turns, and Timeline calls go through one
/// ``GnosticConsumerSession`` and its clients. This type adds only what ACP
/// needs on top: Ascendant selection, Timeline presence for the session
/// registry, fast failure once a provider is evicted, and the ACP error
/// vocabulary.
@MainActor
public final class RemoteTurnClient: Sendable {
    public struct DiscoveredAscendant: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let timelineID: UUID
        public let providerID: String
        /// The serving node identity, when the serve advertises one. It is
        /// stable across serve processes; `providerID` is not.
        public let nodeID: UUID?
        public let capabilities: [String]

        public init(
            id: UUID,
            name: String,
            timelineID: UUID,
            providerID: String,
            nodeID: UUID? = nil,
            capabilities: [String] = []
        ) {
            self.id = id
            self.name = name
            self.timelineID = timelineID
            self.providerID = providerID
            self.nodeID = nodeID
            self.capabilities = capabilities
        }
    }
    public let host: String
    public let port: Int
    public let namespace: String
    public let username: String?
    public let password: String?
    private let session: GnosticConsumerSession
    private let timeout: Duration
    private let promptTimeout: Duration
    private var turns: GnosticTurnClient?
    private var timelines: GnosticTimelineClient?
    private var providerEvictionTask: Task<Void, Never>?
    private var offlineProviders: Set<String> = []
    private var inFlightCalls: [String: [UUID: @MainActor () -> Void]] = [:]

    /// Creates a client bound to a broker namespace.
    ///
    /// Empty credential strings are treated as absent so the client never asks
    /// the broker to authenticate with a blank username or password.
    public init(
        host: String,
        port: Int,
        namespace: String,
        username: String? = nil,
        password: String? = nil,
        timeout: Duration = .seconds(5),
        promptTimeout: Duration? = nil
    ) throws {
        let broker = GnosticBrokerSettings(
            host: host,
            port: port,
            namespace: namespace,
            username: username,
            password: password
        )
        self.host = host
        self.port = port
        self.namespace = namespace
        self.username = broker.username
        self.password = broker.password
        self.timeout = timeout
        self.promptTimeout = promptTimeout ?? timeout
        session = try GnosticConsumerSession(
            broker: broker,
            identityName: "gnostic-turn-client",
            connectTimeout: Self.connectTimeout,
            discoverTimeout: timeout
        )
    }

    /// The bounded window in which the broker must come online.
    static let connectTimeout: Duration = .seconds(10)

    /// Connects and subscribes to Gnostic object advertisements.
    public func connect() async throws {
        startProviderEvictionMonitor(await session.catalogUpdates())
        do {
            try await session.start()
        } catch let error as GnosticConsumerSessionError {
            providerEvictionTask?.cancel()
            switch error {
            case let .brokerUnreachable(detail), let .connectionFailed(detail):
                throw RemoteTurnClientError.brokerUnreachable(detail)
            case .invalidCredentials, .notStarted, .alreadyStopped:
                throw RemoteTurnClientError.brokerUnreachable(error.errorDescription ?? error.reasonCode)
            }
        }
        turns = try session.turnClient(timeout: timeout, promptTimeout: promptTimeout)
        timelines = try session.timelineClient(timeout: timeout)
    }

    /// Stops the client's session with ordered cleanup.
    public func stop() async {
        providerEvictionTask?.cancel()
        providerEvictionTask = nil
        await session.stop()
    }

    /// Observes catalog provider evictions so their in-flight and later calls
    /// fail without waiting for the call or prompt timeout.
    private func startProviderEvictionMonitor(_ changes: AsyncStream<NetworkCatalogChange>) {
        providerEvictionTask?.cancel()
        providerEvictionTask = Task { @MainActor [weak self] in
            for await change in changes {
                guard case let .providerEvicted(providerID) = change else { continue }
                self?.providerEvicted(providerID)
            }
        }
    }

    private func providerEvicted(_ providerID: String) {
        let normalized = providerID.lowercased()
        offlineProviders.insert(normalized)
        inFlightCalls[normalized]?.values.forEach { $0() }
    }

    private func ensureProviderOnline(_ providerID: String?) throws {
        guard let providerID, offlineProviders.contains(providerID.lowercased()) else { return }
        throw RemoteTurnClientError.providerOffline(providerID)
    }

    /// Whether the underlying broker connection has been lost since connect.
    public var hasLostConnection: Bool { session.hasLostConnection }

    /// Providers observed offline through a lifecycle identity deadvertisement.
    /// Diagnostic surface for tests and inspection; not part of the ACP contract.
    var evictedProviderIDs: Set<String> { offlineProviders }

    /// Returns provider-scoped discovered objects after one active refresh.
    public func listNetworkObjects() async -> [NetworkCatalogEntry] {
        try? await session.discover()
        return await session.networkObjects()
    }

    private func discoverAscendants() async -> [DiscoveredAscendant] {
        discoveredAscendants(from: await listNetworkObjects())
    }

    private func discoveredAscendants(from entries: [NetworkCatalogEntry]) -> [DiscoveredAscendant] {
        entries
            .filter { $0.objectType == GnosticObjectType.ascendant }
            .compactMap { entry in
                guard case let .string(raw) = entry.knownProperties["privateTimelineID"],
                      let timelineID = UUID(uuidString: raw) else { return nil }
                return DiscoveredAscendant(
                    id: entry.objectID,
                    name: entry.name,
                    timelineID: timelineID,
                    providerID: entry.providerID,
                    nodeID: Self.nodeID(of: entry),
                    capabilities: entry.advertisedCapabilities
                )
            }
            .sorted { ($0.id.uuidString, $0.providerID) < ($1.id.uuidString, $1.providerID) }
    }

    /// Runs an identified Turn. Supplying a stable id enables serve-lifetime
    /// deduplication; `nil` preserves the non-idempotent request shape.
    public func turn(
        message: String,
        timelineID: UUID,
        clientTurnID: String?,
        providerID: String? = nil
    ) async throws -> AscendantTurnResult {
        let turns = try connectedTurns()
        return try await tracked(providerID) {
            try await turns.run(message: message, timelineID: timelineID, clientTurnID: clientTurnID, providerID: providerID)
        }
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
        let turns = try connectedTurns()
        return try await tracked(providerID) {
            try await turns.replay(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                message: message,
                afterSequence: afterSequence,
                providerID: providerID
            )
        }
    }

    /// Streams the live updates for one identified Turn until its terminal
    /// update.
    public func turnUpdates(
        for clientTurnID: String,
        timelineID: UUID,
        providerID: String
    ) async throws -> AsyncStream<AscendantTurnUpdate> {
        try await connectedTurns().updates(for: clientTurnID, timelineID: timelineID, providerID: providerID)
    }

    public func respondToPermission(_ permission: AscendantPermissionResponse, providerID: String) throws {
        try connectedTurns().respond(to: permission, providerID: providerID)
    }

    /// Reads a Timeline's attachment state from the given provider.
    public func timelineStatus(timelineID: UUID, providerID: String? = nil) async throws -> TimelineStatus {
        let timelines = try connectedTimelines()
        return try await tracked(providerID) {
            try await timelines.status(timelineID: timelineID, providerID: providerID)
        }
    }

    /// Creates a new Timeline under a discovered Ascendant.
    public func createTimeline(
        title: String,
        ascendantID: UUID,
        providerID: String? = nil
    ) async throws -> TimelineStatus {
        let timelines = try connectedTimelines()
        return try await tracked(providerID) {
            try await timelines.create(title: title, ascendantID: ascendantID, providerID: providerID)
        }
    }

    public func selectAscendant(
        id ascendantID: UUID? = nil,
        providerID: String? = nil,
        nodeID: UUID? = nil
    ) async throws -> DiscoveredAscendant {
        try Self.selectCandidate(
            from: await discoverAscendants(),
            id: ascendantID,
            providerID: providerID,
            nodeID: nodeID
        )
    }

    static func selectCandidate(
        from candidates: [DiscoveredAscendant],
        id ascendantID: UUID? = nil,
        providerID: String? = nil,
        nodeID: UUID? = nil
    ) throws -> DiscoveredAscendant {
        if ascendantID != nil || providerID != nil || nodeID != nil {
            let matches = candidates.filter {
                (ascendantID == nil || $0.id == ascendantID)
                    && (providerID == nil || $0.providerID.lowercased() == providerID?.lowercased())
                    && (nodeID == nil || $0.nodeID == nil || $0.nodeID == nodeID)
            }
            guard let candidate = matches.first else {
                if let nodeID, candidates.contains(where: { ascendantID == nil || $0.id == ascendantID }) {
                    throw RemoteTurnClientError.nodeUnavailable(nodeID)
                }
                if let ascendantID { throw RemoteTurnClientError.ascendantUnavailable(ascendantID) }
                throw RemoteTurnClientError.providerUnavailable(providerID ?? "")
            }
            guard matches.count == 1 else { throw RemoteTurnClientError.ambiguousAscendant }
            guard candidate.capabilities.contains(GnosticCapability.textTurnInput) else {
                throw RemoteTurnClientError.missingCapability(GnosticCapability.textTurnInput)
            }
            return candidate
        }
        guard !candidates.isEmpty else { throw RemoteTurnClientError.noServedAscendant }
        let capable = candidates.filter { $0.capabilities.contains(GnosticCapability.textTurnInput) }
        guard !capable.isEmpty else { throw RemoteTurnClientError.missingCapability(GnosticCapability.textTurnInput) }
        guard capable.count == 1 else {
            throw RemoteTurnClientError.ambiguousAscendant
        }
        return capable[0]
    }

    /// Refreshes discovery once and returns a snapshot that answers Timeline
    /// presence for any number of identifiers.
    ///
    /// ACP reconciles a durable session registry against the live environment,
    /// so it needs one catalog refresh for the whole registry rather than one
    /// per record.
    public func timelinePresenceSnapshot() async -> TimelinePresenceSnapshot {
        let entries = await listNetworkObjects()
        var providersByTimeline: [UUID: Set<String>] = [:]
        for entry in entries where entry.objectType == GnosticObjectType.timeline {
            providersByTimeline[entry.objectID, default: []].insert(entry.providerID)
        }
        return TimelinePresenceSnapshot(
            providersByTimeline: providersByTimeline,
            hasDiscoveredNode: entries.contains { $0.objectType == GnosticObjectType.ascendant }
        )
    }

    /// Reads the stable serving node identity from a catalog entry.
    nonisolated static func nodeID(of entry: NetworkCatalogEntry) -> UUID? {
        guard case let .string(raw) = entry.knownProperties["nodeID"] else { return nil }
        return UUID(uuidString: raw)
    }

    /// Reports whether one Timeline is discoverable on a live Node.
    public func timelinePresence(of timelineID: UUID) async -> TimelinePresence {
        await timelinePresenceSnapshot().presence(of: timelineID)
    }

    private func connectedTurns() throws -> GnosticTurnClient {
        guard let turns else { throw RemoteTurnClientError.brokerUnreachable("not connected") }
        return turns
    }

    private func connectedTimelines() throws -> GnosticTimelineClient {
        guard let timelines else { throw RemoteTurnClientError.brokerUnreachable("not connected") }
        return timelines
    }

    /// Runs one provider-addressed operation so a provider eviction cancels it
    /// and reports ``RemoteTurnClientError/providerOffline(_:)``.
    private func tracked<Value: Sendable>(
        _ providerID: String?,
        _ operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try ensureProviderOnline(providerID)
        let task = Task { @MainActor in try await operation() }
        let normalized = providerID?.lowercased()
        let callID = UUID()
        if let normalized {
            inFlightCalls[normalized, default: [:]][callID] = { task.cancel() }
        }
        defer {
            if let normalized {
                inFlightCalls[normalized]?[callID] = nil
                if inFlightCalls[normalized]?.isEmpty == true {
                    inFlightCalls[normalized] = nil
                }
            }
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            // A provider eviction cancels this call. Report the typed offline
            // error instead of the generic cancellation it produces.
            try ensureProviderOnline(providerID)
            throw Self.remoteError(error)
        }
    }

    /// Maps the public client failures onto the ACP error vocabulary. Serve
    /// rejections and transport failures keep their public client error.
    private static func remoteError(_ error: any Error) -> any Error {
        switch error {
        case let error as GnosticTurnClientError:
            switch error {
            case let .timelineUnavailable(id): RemoteTurnClientError.timelineUnavailable(id)
            case let .timelineAmbiguous(id): RemoteTurnClientError.timelineAmbiguous(id)
            case .providerMismatch: RemoteTurnClientError.providerMismatch
            case let .missingCapability(capability): RemoteTurnClientError.missingCapability(capability)
            case .callFailed: error
            }
        case let error as GnosticTimelineClientError:
            switch error {
            case let .ascendantUnavailable(id): RemoteTurnClientError.ascendantUnavailable(id)
            case .ascendantAmbiguous: RemoteTurnClientError.ambiguousAscendant
            case let .timelineUnavailable(id): RemoteTurnClientError.timelineUnavailable(id)
            case let .timelineAmbiguous(id): RemoteTurnClientError.timelineAmbiguous(id)
            case .providerMismatch: RemoteTurnClientError.providerMismatch
            case let .missingCapability(capability): RemoteTurnClientError.missingCapability(capability)
            case .callFailed: error
            }
        default:
            error
        }
    }
}
