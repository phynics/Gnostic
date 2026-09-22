// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// A public client that creates and renames remote Timelines.
///
/// The client shares the Axoloty transport owned by the
/// ``GnosticConsumerSession`` that created it. It opens no second connection,
/// hosts no Node, and advertises nothing. Each operation resolves the serving
/// provider from the session catalog and requires the Ascendant to advertise
/// ``GnosticCapability/timelineManagement``.
///
/// Timeline deletion is not exposed because no delete operation exists in the
/// Gnostic wire contract.
@MainActor
public final class GnosticTimelineClient {
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let timeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration
    ) {
        self.manager = manager
        self.catalog = catalog
        self.subscription = subscription
        self.timeout = timeout
    }

    /// Creates a Timeline under a discovered Ascendant.
    ///
    /// - Parameters:
    ///   - title: The new Timeline title.
    ///   - ascendantID: The Ascendant that will operate the Timeline.
    /// - Returns: The status returned by the serving Node.
    /// - Throws: ``GnosticTimelineClientError`` when the Ascendant cannot be
    ///   resolved, lacks Timeline management, or the serve rejects the call.
    public func create(title: String, ascendantID: UUID) async throws -> TimelineStatus {
        let providerID = try await resolvedAscendantProvider(for: ascendantID)
        let payload = try GnosticWirePayload.encode(
            TimelineCreateRequest(title: title, ascendantID: ascendantID),
            context: "timeline.create request"
        )
        let response = try await call(
            operation: TimelineManagementProvider.createOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: providerID
        )
        return try Self.decode(TimelineStatus.self, from: response.result)
    }

    /// Renames a discovered Timeline.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline to rename.
    ///   - title: The replacement title.
    /// - Returns: The status returned by the serving Node.
    /// - Throws: ``GnosticTimelineClientError`` when the Timeline cannot be
    ///   resolved, its Ascendant lacks Timeline management, or the serve
    ///   rejects the call.
    public func update(timelineID: UUID, title: String) async throws -> TimelineStatus {
        let providerID = try await resolvedTimelineProvider(for: timelineID)
        let ascendantID = try await resolvedAscendantID(for: timelineID, providerID: providerID)
        try await requireTimelineManagementCapability(ascendantID: ascendantID, providerID: providerID)
        let payload = try GnosticWirePayload.encode(
            TimelineUpdateRequest(timelineID: timelineID, title: title),
            context: "timeline.update request"
        )
        let response = try await call(
            operation: TimelineManagementProvider.updateOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: providerID
        )
        return try Self.decode(TimelineStatus.self, from: response.result)
    }

    private func resolvedAscendantProvider(for ascendantID: UUID) async throws -> String {
        var entries = await catalog.networkObjects()
        if !entries.contains(where: {
            $0.objectType == GnosticObjectType.ascendant && $0.objectID == ascendantID
        }) {
            await subscription.discover(using: manager, timeout: timeout)
            entries = await catalog.networkObjects()
        }
        let ascendants = entries.filter {
            $0.objectType == GnosticObjectType.ascendant && $0.objectID == ascendantID
        }
        guard let providerID = ascendants.first?.providerID else {
            throw GnosticTimelineClientError.ascendantUnavailable(ascendantID)
        }
        let providers = Set(ascendants.map { $0.providerID.lowercased() })
        guard providers.count == 1 else {
            throw GnosticTimelineClientError.ascendantAmbiguous(ascendantID)
        }
        guard Self.capabilities(of: ascendants[0]).contains(GnosticCapability.timelineManagement) else {
            throw GnosticTimelineClientError.missingCapability(GnosticCapability.timelineManagement)
        }
        return providerID
    }

    private func resolvedTimelineProvider(for timelineID: UUID) async throws -> String {
        var entries = await catalog.networkObjects()
        if !entries.contains(where: {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
        }) {
            await subscription.discover(using: manager, timeout: timeout)
            entries = await catalog.networkObjects()
        }
        let timelines = entries.filter {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
        }
        guard let providerID = timelines.first?.providerID else {
            throw GnosticTimelineClientError.timelineUnavailable(timelineID)
        }
        let providers = Set(timelines.map { $0.providerID.lowercased() })
        guard providers.count == 1 else {
            throw GnosticTimelineClientError.timelineAmbiguous(timelineID)
        }
        return providerID
    }

    private func resolvedAscendantID(for timelineID: UUID, providerID: String) async throws -> UUID {
        let entries = await catalog.networkObjects()
        let timelines = entries.filter {
            $0.objectType == GnosticObjectType.timeline
                && $0.objectID == timelineID
                && $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
        }
        let ascendantIDs = Set(timelines.compactMap { entry -> UUID? in
            guard case let .string(raw) = entry.knownProperties["attachedAscendantID"] else { return nil }
            return UUID(uuidString: raw)
        })
        guard ascendantIDs.count == 1, let ascendantID = ascendantIDs.first else {
            throw GnosticTimelineClientError.timelineUnavailable(timelineID)
        }
        return ascendantID
    }

    private func requireTimelineManagementCapability(ascendantID: UUID, providerID: String) async throws {
        let entries = await catalog.networkObjects()
        guard entries.contains(where: { entry in
            entry.objectType == GnosticObjectType.ascendant
                && entry.objectID == ascendantID
                && entry.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && Self.capabilities(of: entry).contains(GnosticCapability.timelineManagement)
        }) else {
            throw GnosticTimelineClientError.missingCapability(GnosticCapability.timelineManagement)
        }
    }

    private func call(
        operation: String,
        parameters: String,
        providerID: String
    ) async throws -> UnaryCallResult {
        let response: UnaryCallResult
        do {
            response = try await manager.call(
                operation: operation,
                parameters: parameters,
                context: Self.providerContext(providerID),
                timeout: timeout
            )
        } catch let failure as RemoteCallFailure {
            let decoded = try? JSONDecoder().decode(
                GnosticProtocolFailure.self,
                from: Data(failure.message.utf8)
            )
            throw GnosticTimelineClientError.callFailed(
                reasonCode: decoded?.reasonCode ?? "callFailed",
                statusCode: decoded?.statusCode ?? failure.code,
                retryable: decoded?.retryable ?? false
            )
        } catch let error as AxolotyError {
            throw Self.transportFailure(error)
        }
        guard response.sourceId?.lowercased() == providerID.lowercased() else {
            throw GnosticTimelineClientError.providerMismatch
        }
        return response
    }

    private static func decode<T: Decodable>(_ type: T.Type, from result: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(result.utf8))
        } catch {
            throw GnosticTimelineClientError.callFailed(reasonCode: "invalidResponse", statusCode: 502, retryable: false)
        }
    }

    private static func transportFailure(_ error: AxolotyError) -> GnosticTimelineClientError {
        switch error {
        case let .runtime(code, _):
            switch code {
            case .timedOut:
                return .callFailed(reasonCode: "callTimedOut", statusCode: 504, retryable: true)
            case .cancelled:
                return .callFailed(reasonCode: "callCancelled", statusCode: 499, retryable: false)
            default:
                return .callFailed(reasonCode: "transportFailure", statusCode: 503, retryable: true)
            }
        default:
            return .callFailed(reasonCode: "transportFailure", statusCode: 503, retryable: true)
        }
    }

    private static func capabilities(of entry: NetworkCatalogEntry) -> [String] {
        guard case let .array(values) = entry.knownProperties["capabilities"] else { return [] }
        return values.compactMap { value in
            guard case let .string(capability) = value else { return nil }
            return capability
        }
    }

    private static func providerContext(_ providerID: String) -> ObjectFilter {
        ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        ))
    }
}
