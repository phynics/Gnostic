// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore

/// Test-only broker fixture access for ACP acceptance tests.
///
/// This deliberately speaks the Gnostic unary operations directly through
/// Axoloty. ACP user interaction remains covered by the JSON-RPC sessions in
/// the acceptance suites, without making those suites depend on the ACP
/// production transport type.
@MainActor
final class ACPBrokerProbe: Sendable {
    struct DiscoveredAscendant: Sendable, Equatable {
        let id: UUID
        let name: String
        let timelineID: UUID
        let providerID: String
        let capabilities: [String]
    }

    enum Error: Swift.Error, Sendable {
        case brokerUnreachable
        case noServedAscendant
        case ambiguousAscendant
        case ascendantUnavailable(UUID)
        case providerUnavailable(String)
        case missingCapability(String)
        case providerMismatch
    }

    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let timeout: Duration

    init(
        host: String,
        port: Int,
        namespace: String,
        timeout: Duration = .seconds(5)
    ) throws {
        self.timeout = timeout
        manager = try CommunicationManager(
            identity: Identity(name: "gnostic-acp-test-probe"),
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

    func connect() async throws {
        let stream = await manager.observeCommunicationStateStream()
        var iterator = stream.makeAsyncIterator()
        try manager.start()
        while let state = await iterator.next() {
            if state == .online {
                try await subscription.start()
                return
            }
        }
        throw Error.brokerUnreachable
    }

    func stop() {
        subscription.stop()
        manager.stop()
    }

    func discoverAscendants() async -> [DiscoveredAscendant] {
        await subscription.discover(using: manager, timeout: timeout)
        return discoveredAscendants(from: await catalog.networkObjects())
    }

    func selectAscendant(
        id ascendantID: UUID? = nil,
        providerID: String? = nil
    ) async throws -> DiscoveredAscendant {
        let candidates = await discoverAscendants()
        if ascendantID != nil || providerID != nil {
            let matches = candidates.filter { candidate in
                guard ascendantID == nil || candidate.id == ascendantID else { return false }
                guard let providerID else { return true }
                return candidate.providerID.caseInsensitiveCompare(providerID) == .orderedSame
            }
            guard let candidate = matches.first else {
                if let ascendantID { throw Error.ascendantUnavailable(ascendantID) }
                throw Error.providerUnavailable(providerID ?? "")
            }
            guard matches.count == 1 else { throw Error.ambiguousAscendant }
            guard candidate.capabilities.contains(GnosticCapability.textTurnInput) else {
                throw Error.missingCapability(GnosticCapability.textTurnInput)
            }
            return candidate
        }

        guard !candidates.isEmpty else { throw Error.noServedAscendant }
        let capable = candidates.filter { $0.capabilities.contains(GnosticCapability.textTurnInput) }
        guard !capable.isEmpty else { throw Error.missingCapability(GnosticCapability.textTurnInput) }
        guard capable.count == 1 else { throw Error.ambiguousAscendant }
        return capable[0]
    }

    func createTimeline(
        title: String,
        ascendantID: UUID,
        providerID: String
    ) async throws -> TimelineStatus {
        let payload = try JSONEncoder().encode(TimelineCreateRequest(title: title, ascendantID: ascendantID))
        let response = try await call(
            operation: TimelineManagementProvider.createOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: providerID
        )
        return try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
    }

    func listTimelines(providerID: String) async throws -> [TimelineStatus] {
        let payload = try JSONEncoder().encode(TimelineListRequest())
        let response = try await call(
            operation: TimelineManagementProvider.listOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: providerID
        )
        return try JSONDecoder().decode(TimelineListResult.self, from: Data(response.result.utf8)).timelines
    }

    func listWorkspaces(providerID: String) async throws -> [WorkspaceListing] {
        let payload = try JSONEncoder().encode(WorkspaceOpsRequest(workspaceID: UUID(), timelineID: UUID()))
        let response = try await call(
            operation: WorkspaceOpsProvider.listOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: providerID
        )
        return try JSONDecoder().decode(WorkspaceListResult.self, from: Data(response.result.utf8)).workspaces
    }

    func attach(workspaceID: UUID, timelineID: UUID, providerID: String) async throws -> Bool {
        let payload = try JSONEncoder().encode(WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: timelineID))
        let response = try await call(
            operation: WorkspaceOpsProvider.attachOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: providerID
        )
        return try JSONDecoder().decode(WorkspaceMutationResult.self, from: Data(response.result.utf8)).accepted
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

    private func call(
        operation: String,
        parameters: String,
        providerID: String
    ) async throws -> UnaryCallResult {
        let response = try await manager.call(
            operation: operation,
            parameters: parameters,
            context: Self.providerContext(providerID),
            timeout: timeout
        )
        guard let sourceID = response.sourceId,
              sourceID.caseInsensitiveCompare(providerID) == .orderedSame else {
            throw Error.providerMismatch
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
