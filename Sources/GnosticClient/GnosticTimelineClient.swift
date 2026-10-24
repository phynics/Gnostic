// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import GnosticProtocol

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
    private let resolver: CatalogTargetResolver
    private let channel: GnosticCallChannel<GnosticTimelineClientError>
    private let timeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration
    ) {
        resolver = CatalogTargetResolver(lookup: GnosticCatalogLookup(
            manager: manager,
            catalog: catalog,
            subscription: subscription,
            timeout: timeout
        ))
        channel = GnosticCallChannel(manager: manager)
        self.timeout = timeout
    }

    /// Creates a Timeline under a discovered Runtime instance.
    ///
    /// - Parameters:
    ///   - title: The new Timeline title.
    ///   - ascendantID: The Runtime identity that will operate the Timeline.
    ///   - providerID: The expected provider of the Ascendant, or `nil` to
    ///     resolve it from the session catalog.
    /// - Returns: The status returned by the serving Node.
    /// - Throws: ``GnosticTimelineClientError`` when the Runtime cannot be
    ///   resolved, the addressed provider does not own it, a legacy Ascendant
    ///   lacks Timeline management, or the serve rejects the call.
    public func create(title: String, ascendantID: UUID, providerID expectedProviderID: String? = nil) async throws -> TimelineStatus {
        let providerID = try await resolvedAscendantProvider(for: ascendantID, expected: expectedProviderID)
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
        let providerID = try await resolvedTimelineProvider(for: timelineID, requiredCapability: GnosticCapability.timelineManagement)
        return try await channel.call(
            TimelineManagementProvider.updateOperation,
            request: TimelineUpdateRequest(timelineID: timelineID, title: title),
            context: "timeline.update request",
            providerID: providerID,
            timeout: timeout,
            returning: TimelineStatus.self
        )
    }

    /// Reads a Timeline's attachment state from its serving Node.
    ///
    /// Unlike the mutating operations, status needs no capability. When
    /// `providerID` is given the client asks that provider directly, without a
    /// catalog refresh, so a caller can probe a Timeline it no longer sees
    /// advertised; a Node that does not own the Timeline rejects the call.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline to read.
    ///   - providerID: The provider to ask, or `nil` to resolve the Timeline's
    ///     provider from the session catalog.
    /// - Returns: The status returned by the serving Node.
    /// - Throws: ``GnosticTimelineClientError`` when the Timeline cannot be
    ///   resolved or the serve rejects the call.
    public func status(timelineID: UUID, providerID explicitProviderID: String? = nil) async throws -> TimelineStatus {
        let providerID: String
        if let explicitProviderID {
            providerID = explicitProviderID
        } else {
            providerID = try await resolvedTimelineProvider(for: timelineID)
        }
        return try await channel.call(
            TimelineStatusProvider.statusOperation,
            request: TimelineStatusRequest(timelineID: timelineID),
            context: "timeline.status request",
            providerID: providerID,
            timeout: timeout,
            returning: TimelineStatus.self
        )
    }

    private func resolvedAscendantProvider(for ascendantID: UUID, expected: String?) async throws -> String {
        switch await resolver.resolve(
            .runtimeInstance,
            id: ascendantID,
            expectedProviderID: expected
        ) {
        case let .success(target): return target.providerID
        case .failure(.unavailable): break
        case .failure(.ambiguous): throw GnosticTimelineClientError.ascendantAmbiguous(ascendantID)
        case .failure(.providerMismatch): throw GnosticTimelineClientError.providerMismatch
        case .failure(.missingCapability): break
        }
        switch await resolver.resolve(
            .ascendant,
            id: ascendantID,
            expectedProviderID: expected,
            requiredCapability: GnosticCapability.timelineManagement
        ) {
        case let .success(target): return target.providerID
        case let .failure(failure): throw Self.error(for: failure, ascendant: ascendantID)
        }
    }

    /// Resolves the Timeline's provider and, when a capability is required,
    /// requires its operating Ascendant to advertise it.
    private func resolvedTimelineProvider(for timelineID: UUID, requiredCapability: String? = nil) async throws -> String {
        switch await resolver.resolve(.timeline, id: timelineID, requiredCapability: requiredCapability) {
        case let .success(target): return target.providerID
        case let .failure(failure): throw Self.error(for: failure, timeline: timelineID)
        }
    }

    /// The one mapping from catalog target failures to Ascendant-addressed
    /// Timeline client errors.
    static func error(for failure: CatalogTargetFailure, ascendant ascendantID: UUID) -> GnosticTimelineClientError {
        switch failure {
        case .unavailable: .ascendantUnavailable(ascendantID)
        case .ambiguous: .ascendantAmbiguous(ascendantID)
        case .providerMismatch: .providerMismatch
        case let .missingCapability(capability): .missingCapability(capability)
        }
    }

    /// The one mapping from catalog target failures to Timeline-addressed
    /// client errors.
    static func error(for failure: CatalogTargetFailure, timeline timelineID: UUID) -> GnosticTimelineClientError {
        switch failure {
        case .unavailable: .timelineUnavailable(timelineID)
        case .ambiguous: .timelineAmbiguous(timelineID)
        case .providerMismatch: .providerMismatch
        case let .missingCapability(capability): .missingCapability(capability)
        }
    }
}
