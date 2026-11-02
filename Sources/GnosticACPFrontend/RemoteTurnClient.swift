// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticClient
import GnosticCore
import GnosticProtocol

/// The ACP adapter over the public consumer facade.
///
/// Connection, discovery, Turns, and Timeline calls go through one
/// ``GnosticConsumerSession`` and its clients. This type adds only what ACP
/// needs on top: Runtime selection, Timeline presence for the session
/// registry, fast failure once a provider is evicted, and the ACP error
/// vocabulary.
@MainActor
public final class RemoteTurnClient: Sendable {
    public struct DiscoveredRuntimeInstance: Sendable, Equatable {
        public let runtimeID: UUID
        public let name: String
        public let providerID: String
        /// The serving node identity, when the serve advertises one. It is
        /// stable across serve processes; `providerID` is not.
        public let nodeID: UUID?

        public init(
            runtimeID: UUID,
            name: String,
            providerID: String,
            nodeID: UUID? = nil
        ) {
            self.runtimeID = runtimeID
            self.name = name
            self.providerID = providerID
            self.nodeID = nodeID
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
    private(set) var runtimeDiscoveryDiagnostics = "Discovery has not run."

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

    static func discoveredRuntimes(from entries: [NetworkCatalogEntry]) -> [DiscoveredRuntimeInstance] {
        entries
            .filter { $0.objectType == GnosticObjectType.runtimeInstance }
            .map { entry in
                DiscoveredRuntimeInstance(
                    runtimeID: entry.objectID,
                    name: entry.name,
                    providerID: entry.providerID,
                    nodeID: Self.nodeID(of: entry)
                )
            }
            .sorted { ($0.runtimeID.uuidString, $0.providerID) < ($1.runtimeID.uuidString, $1.providerID) }
    }

    /// Runs an identified Turn. Supplying a stable id enables serve-lifetime
    /// deduplication; `nil` preserves the non-idempotent request shape.
    public func turn(
        message: String,
        timelineID: UUID,
        clientTurnID: String?,
        providerID: String? = nil
    ) async throws -> TurnResult {
        let turns = try connectedTurns()
        return try await tracked(providerID) {
            try await turns.run(message: message, timelineID: timelineID, clientTurnID: clientTurnID, providerID: providerID)
        }
    }

    /// Sends an explicit cancellation for one identified Timeline Turn.
    public func cancelTurn(
        timelineID: UUID,
        clientTurnID: String,
        providerID: String
    ) async throws -> Bool {
        let turns = try connectedTurns()
        return try await tracked(providerID) {
            try await turns.cancel(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                providerID: providerID
            )
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
    ) async throws -> TurnReplay {
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
    ) async throws -> AsyncStream<TurnUpdate> {
        try await connectedTurns().updates(for: clientTurnID, timelineID: timelineID, providerID: providerID)
    }

    public func respondToPermission(_ permission: TurnPermissionResponse, providerID: String) throws {
        try connectedTurns().respond(to: permission, providerID: providerID)
    }

    /// Reads a Timeline's attachment state from the given provider.
    public func timelineStatus(timelineID: UUID, providerID: String? = nil) async throws -> TimelineStatus {
        let timelines = try connectedTimelines()
        return try await tracked(providerID) {
            try await timelines.status(timelineID: timelineID, providerID: providerID)
        }
    }

    /// Creates a new Timeline for the selected Runtime instance.
    public func createTimeline(
        title: String,
        runtimeID: UUID,
        providerID: String? = nil
    ) async throws -> TimelineStatus {
        let timelines = try connectedTimelines()
        return try await tracked(providerID) {
            try await timelines.create(title: title, runtimeInstanceID: runtimeID, providerID: providerID)
        }
    }

    /// Selects one compatible Runtime advertisement; Timeline creation happens separately.
    public func selectRuntime(
        id runtimeID: UUID? = nil,
        providerID: String? = nil,
        nodeID: UUID? = nil
    ) async throws -> DiscoveredRuntimeInstance {
        try await session.discover()
        let entries = await session.networkObjects(includeIncompatible: true)
        runtimeDiscoveryDiagnostics = Self.discoverySummary(entries)
        return try Self.selectCandidate(
            from: Self.discoveredRuntimes(from: entries.filter(\.isProtocolCompatible)),
            id: runtimeID,
            providerID: providerID,
            nodeID: nodeID
        )
    }

    static func discoverySummary(_ entries: [NetworkCatalogEntry]) -> String {
        let entryLimit = 8
        let fieldLimit = 64
        let objectTypes = Dictionary(grouping: entries.prefix(entryLimit), by: \.objectType)
            .map { "\(safeDiagnosticField($0.key, limit: fieldLimit)):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        let runtimeCount = entries.reduce(into: 0) { count, entry in
            if entry.objectType == GnosticObjectType.runtimeInstance { count += 1 }
        }
        let runtimeEntries = entries.lazy.filter { $0.objectType == GnosticObjectType.runtimeInstance }
        let summaries = runtimeEntries.prefix(entryLimit).map { entry in
            let kind: String
            if case let .string(raw)? = entry.knownProperties["runtimeKind"] {
                kind = safeDiagnosticField(raw, limit: fieldLimit)
            } else {
                kind = "missing"
            }
            let node = Self.nodeID(of: entry)?.uuidString.lowercased() ?? "missing"
            let protocolMajor = entry.protocolMajor.map { String($0) } ?? "missing"
            let capabilityCount: Int
            if case let .object(capabilities)? = entry.knownProperties["rawCapabilities"] {
                capabilityCount = capabilities.count
            } else {
                capabilityCount = 0
            }
            let capabilityCountText = capabilityCount > 999 ? "999+" : String(capabilityCount)
            return "id=\(entry.objectID.uuidString.lowercased()),provider=\(safeDiagnosticField(entry.providerID, limit: fieldLimit)),node=\(node),kind=\(kind),protocol=\(protocolMajor),capabilityCount=\(capabilityCountText),compatible=\(entry.isProtocolCompatible)"
        }
        let omittedEntries = max(0, entries.count - entryLimit)
        let omittedRuntimes = max(0, runtimeCount - entryLimit)
        let summary = "catalogObjectTypes=[\(objectTypes)]; catalogRuntimes=[\(summaries.joined(separator: "; "))]; omittedEntries=\(omittedEntries); omittedRuntimes=\(omittedRuntimes)\(omittedEntries > 0 || omittedRuntimes > 0 ? "; truncated=true" : "")"
        guard summary.count > 1_024 else { return summary }
        return String(summary.prefix(1_008)) + "; truncated=true"
    }

    static func discoveryFailureDescription(error: Error, diagnostics: String) -> String {
        let message = safeDiagnosticField(error.localizedDescription, limit: 256)
        let details = safeDiagnosticField(diagnostics, limit: 1_024)
        let response = "\(message) Discovery details: \(details)"
        guard response.count <= 1_320 else {
            return String(response.prefix(1_304)) + "; truncated=true"
        }
        return response
    }

    private static func safeDiagnosticField(_ value: String, limit: Int) -> String {
        var scalars = value.unicodeScalars.makeIterator()
        var characters: [Character] = []
        characters.reserveCapacity(limit)
        while characters.count < limit, let scalar = scalars.next() {
            characters.append(CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar))
        }
        let truncated = scalars.next() != nil
        return String(characters) + (truncated ? "…" : "")
    }

    static func selectCandidate(
        from candidates: [DiscoveredRuntimeInstance],
        id runtimeID: UUID? = nil,
        providerID: String? = nil,
        nodeID: UUID? = nil
    ) throws -> DiscoveredRuntimeInstance {
        if runtimeID != nil || providerID != nil || nodeID != nil {
            let matches = candidates.filter {
                (runtimeID == nil || $0.runtimeID == runtimeID)
                    && (providerID == nil || $0.providerID.lowercased() == providerID?.lowercased())
                    && (nodeID == nil || $0.nodeID == nodeID)
            }
            guard let candidate = matches.first else {
                if let nodeID, candidates.contains(where: { runtimeID == nil || $0.runtimeID == runtimeID }) {
                    throw RemoteTurnClientError.nodeUnavailable(nodeID)
                }
                if let runtimeID { throw RemoteTurnClientError.runtimeUnavailable(runtimeID) }
                throw RemoteTurnClientError.providerUnavailable(providerID ?? "")
            }
            guard matches.count == 1 else { throw RemoteTurnClientError.ambiguousRuntime }
            return candidate
        }
        guard !candidates.isEmpty else { throw RemoteTurnClientError.noRuntime }
        guard candidates.count == 1 else {
            throw RemoteTurnClientError.ambiguousRuntime
        }
        return candidates[0]
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
            hasDiscoveredNode: entries.contains { $0.objectType == GnosticObjectType.runtimeInstance }
        )
    }

    /// Reads the stable serving node identity from a catalog entry.
    public nonisolated static func nodeID(of entry: NetworkCatalogEntry) -> UUID? {
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
    static func remoteError(_ error: any Error) -> any Error {
        switch error {
        case let error as GnosticTurnClientError:
            switch error {
            case let .timelineUnavailable(id): RemoteTurnClientError.timelineUnavailable(id)
            case let .timelineAmbiguous(id): RemoteTurnClientError.timelineAmbiguous(id)
            case .providerMismatch: RemoteTurnClientError.providerMismatch
            case let .missingCapability(capability): RemoteTurnClientError.missingCapability(capability)
            case let .callFailed(reasonCode, _, _):
                switch reasonCode {
                case "promptTooLarge": RemoteTurnClientError.promptTooLarge
                case "timelineBusy": RemoteTurnClientError.timelineBusy
                case "insertionUnknown": RemoteTurnClientError.insertionUnknown
                case "timelineQuarantined": RemoteTurnClientError.timelineQuarantined
                default: error
                }
            }
        case let error as GnosticWirePayload.Error:
            if case .tooLarge = error { RemoteTurnClientError.promptTooLarge } else { error }
        case let error as GnosticTimelineClientError:
            switch error {
            case let .runtimeInstanceUnavailable(id): RemoteTurnClientError.ascendantUnavailable(id)
            case .runtimeInstanceAmbiguous: RemoteTurnClientError.ambiguousAscendant
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
