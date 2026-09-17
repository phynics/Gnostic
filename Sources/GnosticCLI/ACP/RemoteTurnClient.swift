// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore

/// A pure-Axoloty transport for ACP's network operations.
///
/// Every interaction is a unary Call/Return over the Axoloty stack
/// (`communication.call(operation:...)`) — no raw MQTT or local runtime.
@MainActor
public final class RemoteTurnClient: Sendable {
    public struct DiscoveredAscendant: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let timelineID: UUID
        public let providerID: String
        public let capabilities: [String]

        public init(id: UUID, name: String, timelineID: UUID, providerID: String, capabilities: [String] = []) {
            self.id = id
            self.name = name
            self.timelineID = timelineID
            self.providerID = providerID
            self.capabilities = capabilities
        }
    }
    public let host: String
    public let port: Int
    public let namespace: String
    public let username: String?
    public let password: String?
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let timeout: Duration
    private let promptTimeout: Duration
    private var stateTask: Task<Void, Never>?
    private var providerEvictionTask: Task<Void, Never>?
    private var connectionLost = false
    private var offlineProviders: Set<String> = []
    private var inFlightCalls: [String: [UUID: Task<UnaryCallResult, Error>]] = [:]

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
        let username = username.flatMap { $0.isEmpty ? nil : $0 }
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        self.host = host
        self.port = port
        self.namespace = namespace
        self.username = username
        self.password = password
        self.timeout = timeout
        self.promptTimeout = promptTimeout ?? timeout
        manager = try CommunicationManager(
            identity: Identity(name: "gnostic-turn-client"),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: host,
                    port: UInt16(port),
                    shouldTryMDNSDiscovery: false,
                    username: username,
                    password: password,
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
                startProviderEvictionMonitor()
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
        throw RemoteTurnClientError.brokerUnreachable("timed out connecting")
    }

    /// Stops the client's manager and subscriptions with ordered cleanup.
    public func stop() async {
        stateTask?.cancel()
        stateTask = nil
        providerEvictionTask?.cancel()
        providerEvictionTask = nil
        await subscription.stopAndWait()
        await subscription.disposeScope()
        manager.stop()
    }

    /// Observes catalog provider evictions so their in-flight and later calls
    /// fail without waiting for the call or prompt timeout.
    private func startProviderEvictionMonitor() {
        providerEvictionTask?.cancel()
        providerEvictionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.catalog.providerEvictionStream()
            for await providerID in stream {
                self.providerEvicted(providerID)
            }
        }
    }

    private func providerEvicted(_ providerID: String) {
        let normalized = providerID.lowercased()
        offlineProviders.insert(normalized)
        if let calls = inFlightCalls[normalized] {
            for task in calls.values {
                task.cancel()
            }
        }
    }

    private func ensureProviderOnline(_ providerID: String?) throws {
        guard let providerID, offlineProviders.contains(providerID.lowercased()) else { return }
        throw RemoteTurnClientError.providerOffline(providerID)
    }

    /// Whether the underlying broker connection has been lost since connect.
    public var hasLostConnection: Bool { connectionLost }

    /// Providers observed offline through a lifecycle identity deadvertisement.
    /// Diagnostic surface for tests and inspection; not part of the ACP contract.
    var evictedProviderIDs: Set<String> { offlineProviders }

    /// Refreshes the catalog using Axoloty's active discover request.
    private func refreshCatalog() async {
        await subscription.discover(using: manager, timeout: timeout)
    }

    /// Returns provider-scoped discovered objects from the current catalog.
    public func listNetworkObjects() async -> [NetworkCatalogEntry] {
        await refreshCatalog()
        return await catalog.networkObjects()
    }

    private func discoverAscendants() async -> [DiscoveredAscendant] {
        await refreshCatalog()
        return discoveredAscendants(from: await catalog.networkObjects())
    }

    private func discoveredAscendants(from entries: [NetworkCatalogEntry]) -> [DiscoveredAscendant] {
        entries
            .filter { $0.objectType == GnosticObjectType.ascendant }
            .compactMap { entry in
                guard case let .string(raw) = entry.knownProperties["privateTimelineID"],
                      let timelineID = UUID(uuidString: raw) else { return nil }
                let capabilities: [String]
                if case let .array(values) = entry.knownProperties["capabilities"] {
                    capabilities = values.compactMap { value in
                        guard case let .string(capability) = value else { return nil }
                        return capability
                    }
                } else {
                    capabilities = []
                }
                return DiscoveredAscendant(
                    id: entry.objectID,
                    name: entry.name,
                    timelineID: timelineID,
                    providerID: entry.providerID,
                    capabilities: capabilities
                )
            }
            .sorted { ($0.id.uuidString, $0.providerID) < ($1.id.uuidString, $1.providerID) }
    }

    /// Runs an identified Turn and returns replay metadata. Supplying a
    /// stable id enables serve-lifetime deduplication; `nil` preserves the
    /// legacy non-idempotent request shape.
    public func turn(
        message: String,
        timelineID: UUID,
        clientTurnID: String?,
        providerID: String? = nil
    ) async throws -> AscendantTurnResult {
        try ensureProviderOnline(providerID)
        let payload = try GnosticWirePayload.encode(
            AscendantTurnRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID)
            , context: "ascendant.turn request")
        let target = try await resolvedTurnTarget(providerID, forTimeline: timelineID)
        try ensureProviderOnline(target.providerID)
        let response = try await call(
            operation: AscendantTurnProvider.turnOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: target.providerID,
            timeout: promptTimeout
        )
        return try JSONDecoder().decode(AscendantTurnResult.self, from: Data(response.result.utf8))
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
        try ensureProviderOnline(providerID)
        let payload = try GnosticWirePayload.encode(
            AscendantTurnReplayRequest(timelineID: timelineID, clientTurnID: clientTurnID, message: message, afterSequence: afterSequence)
            , context: "ascendant.turn.replay request")
        let target = try await resolvedTurnTarget(providerID, forTimeline: timelineID)
        try ensureProviderOnline(target.providerID)
        let response = try await call(
            operation: AscendantTurnProvider.replayOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: target.providerID,
            timeout: timeout
        )
        return try JSONDecoder().decode(AscendantTurnReplay.self, from: Data(response.result.utf8))
    }

    public func observeTurnUpdates(providerID: String? = nil) async throws -> AsyncStream<AscendantTurnUpdateStore.Event> {
        let snapshots = try await manager.observeChannelStream(channelId: AscendantTurnProvider.updateChannel)
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

    public func respondToPermission(_ permission: AscendantPermissionResponse, providerID: String? = nil) async throws {
        manager.publishChannel(try AscendantPermissionProvider.responseEvent(permission.targeted(to: providerID)))
    }

    /// Reads the served timeline's attachment state.
    public func timelineStatus(timelineID: UUID, providerID: String? = nil) async throws -> TimelineStatus {
        try ensureProviderOnline(providerID)
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
        try ensureProviderOnline(providerID)
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

    public func selectAscendant(id ascendantID: UUID? = nil, providerID: String? = nil) async throws -> DiscoveredAscendant {
        try Self.selectCandidate(from: await discoverAscendants(), id: ascendantID, providerID: providerID)
    }

    static func selectCandidate(
        from candidates: [DiscoveredAscendant],
        id ascendantID: UUID? = nil,
        providerID: String? = nil
    ) throws -> DiscoveredAscendant {
        if ascendantID != nil || providerID != nil {
            let matches = candidates.filter {
                (ascendantID == nil || $0.id == ascendantID)
                    && (providerID == nil || $0.providerID.lowercased() == providerID?.lowercased())
            }
            guard let candidate = matches.first else {
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
        await refreshCatalog()
        let entries = await catalog.networkObjects()
        var providersByTimeline: [UUID: Set<String>] = [:]
        for entry in entries where entry.objectType == GnosticObjectType.timeline {
            providersByTimeline[entry.objectID, default: []].insert(entry.providerID)
        }
        return TimelinePresenceSnapshot(
            providersByTimeline: providersByTimeline,
            hasDiscoveredNode: entries.contains { $0.objectType == GnosticObjectType.ascendant }
        )
    }

    /// Reports whether one Timeline is discoverable on a live Node.
    public func timelinePresence(of timelineID: UUID) async -> TimelinePresence {
        await timelinePresenceSnapshot().presence(of: timelineID)
    }

    private func discoveredProviderID(forTimeline timelineID: UUID) async throws -> String {
        switch await timelinePresence(of: timelineID) {
        case let .present(providerID): return providerID
        case .ambiguous: throw RemoteTurnClientError.timelineAmbiguous(timelineID)
        case .absent, .indeterminate: throw RemoteTurnClientError.timelineUnavailable(timelineID)
        }
    }

    private func resolvedProviderID(_ explicit: String?, forTimeline timelineID: UUID) async throws -> String {
        if let explicit { return explicit }
        return try await discoveredProviderID(forTimeline: timelineID)
    }

    private func resolvedTurnTarget(_ explicitProviderID: String?, forTimeline timelineID: UUID) async throws -> (providerID: String, ascendantID: UUID) {
        await refreshCatalog()
        let entries = await catalog.networkObjects()
        let timelines = entries.filter {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
        }
        let providers = Set(timelines.map(\.providerID))
        guard let providerID = providers.first else { throw RemoteTurnClientError.timelineUnavailable(timelineID) }
        guard providers.count == 1 else { throw RemoteTurnClientError.timelineAmbiguous(timelineID) }
        if let explicitProviderID,
           explicitProviderID.caseInsensitiveCompare(providerID) != .orderedSame {
            throw RemoteTurnClientError.providerMismatch
        }
        let attachedAscendantIDs = Set(timelines.compactMap { entry -> UUID? in
            guard case let .string(raw) = entry.knownProperties["attachedAscendantID"] else { return nil }
            return UUID(uuidString: raw)
        })
        guard attachedAscendantIDs.count == 1,
              let ascendantID = attachedAscendantIDs.first else {
            throw RemoteTurnClientError.timelineUnavailable(timelineID)
        }
        guard discoveredAscendants(from: entries).contains(where: {
            $0.id == ascendantID
                && $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && $0.capabilities.contains(GnosticCapability.textTurnInput)
        }) else {
            throw RemoteTurnClientError.missingCapability(GnosticCapability.textTurnInput)
        }
        return (providerID, ascendantID)
    }

    private func call(operation: String, parameters: String? = nil, providerID: String?, timeout: Duration) async throws -> UnaryCallResult {
        try ensureProviderOnline(providerID)
        let normalized = providerID?.lowercased()
        let callID = UUID()
        let task = Task { [manager] in
            try await manager.call(
                operation: operation,
                parameters: parameters,
                context: providerID.map(Self.providerContext),
                timeout: timeout
            )
        }
        if let normalized {
            inFlightCalls[normalized, default: [:]][callID] = task
        }
        defer {
            if let normalized {
                inFlightCalls[normalized]?[callID] = nil
                if inFlightCalls[normalized]?.isEmpty == true {
                    inFlightCalls[normalized] = nil
                }
            }
        }
        let response: UnaryCallResult
        do {
            response = try await task.value
        } catch {
            // A provider eviction cancels this call. Report the typed offline
            // error instead of the generic cancellation it produces.
            try ensureProviderOnline(providerID)
            throw error
        }
        if let providerID, response.sourceId?.lowercased() != providerID.lowercased() {
            throw RemoteTurnClientError.providerMismatch
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
