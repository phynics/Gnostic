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
    private let lookup: GnosticCatalogLookup
    private let channel: GnosticCallChannel<GnosticTimelineClientError>
    private let timeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration
    ) {
        lookup = GnosticCatalogLookup(manager: manager, catalog: catalog, subscription: subscription, timeout: timeout)
        channel = GnosticCallChannel(manager: manager)
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
        return try await channel.call(
            TimelineManagementProvider.createOperation,
            request: TimelineCreateRequest(title: title, ascendantID: ascendantID),
            context: "timeline.create request",
            providerID: providerID,
            timeout: timeout,
            returning: TimelineStatus.self
        )
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
        return try await channel.call(
            TimelineManagementProvider.updateOperation,
            request: TimelineUpdateRequest(timelineID: timelineID, title: title),
            context: "timeline.update request",
            providerID: providerID,
            timeout: timeout,
            returning: TimelineStatus.self
        )
    }

    private func resolvedAscendantProvider(for ascendantID: UUID) async throws -> String {
        let entries = await lookup.entries(requiring: GnosticObjectType.ascendant, id: ascendantID)
        switch GnosticCatalogLookup.provider(of: GnosticObjectType.ascendant, id: ascendantID, in: entries) {
        case let .provider(providerID):
            guard GnosticCatalogLookup.ascendantAdvertises(
                GnosticCapability.timelineManagement,
                ascendantID: ascendantID,
                providerID: providerID,
                in: entries
            ) else {
                throw GnosticTimelineClientError.missingCapability(GnosticCapability.timelineManagement)
            }
            return providerID
        case .unavailable, .mismatch: throw GnosticTimelineClientError.ascendantUnavailable(ascendantID)
        case .ambiguous: throw GnosticTimelineClientError.ascendantAmbiguous(ascendantID)
        }
    }

    /// Resolves the Timeline's provider and requires its operating Ascendant to
    /// advertise Timeline management.
    private func resolvedTimelineProvider(for timelineID: UUID) async throws -> String {
        let entries = await lookup.entries(requiring: GnosticObjectType.timeline, id: timelineID)
        let providerID: String
        switch GnosticCatalogLookup.provider(of: GnosticObjectType.timeline, id: timelineID, in: entries) {
        case let .provider(resolved): providerID = resolved
        case .unavailable, .mismatch: throw GnosticTimelineClientError.timelineUnavailable(timelineID)
        case .ambiguous: throw GnosticTimelineClientError.timelineAmbiguous(timelineID)
        }
        guard let ascendantID = GnosticCatalogLookup.operatingAscendantID(
            ofTimeline: timelineID,
            providerID: providerID,
            in: entries
        ) else {
            throw GnosticTimelineClientError.timelineUnavailable(timelineID)
        }
        guard GnosticCatalogLookup.ascendantAdvertises(
            GnosticCapability.timelineManagement,
            ascendantID: ascendantID,
            providerID: providerID,
            in: entries
        ) else {
            throw GnosticTimelineClientError.missingCapability(GnosticCapability.timelineManagement)
        }
        return providerID
    }
}
