// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// A public client that reads payload-free live diagnostics from a discovered Node.
///
/// The client shares the Axoloty transport owned by the
/// ``GnosticConsumerSession`` that created it. It opens no second connection,
/// hosts no Node, and advertises nothing. Every call resolves its target from
/// the session catalog; discovery is refreshed only when the target is absent.
///
/// ## Capability gating
///
/// Diagnostics are additive. A Node advertises
/// ``GnosticCapability/diagnostics`` on its Ascendant projections. When no
/// discovered provider advertises the capability, every method fails with
/// ``GnosticDiagnosticsClientError/missingCapability(_:)`` before any wire
/// call. A session that talks to an older or non-diagnostic Node therefore
/// degrades clearly instead of receiving an unknown-operation error.
///
/// ## Payload safety
///
/// Every result carries counts, identifiers, health, and effective status. It
/// never carries a Turn body, a secret, or provider-native state. The calls
/// are read-only and never mutate the Node.
///
/// ## Lifetime
///
/// The client is valid only while its session is running. After
/// ``GnosticConsumerSession/stop()`` the shared transport is gone and later
/// calls fail by transport timeout; create a new client from a new session
/// instead.
@MainActor
public final class GnosticDiagnosticsClient {
    private let catalog: NetworkCatalog
    private let lookup: GnosticCatalogLookup
    private let channel: GnosticCallChannel<GnosticDiagnosticsClientError>
    private let timeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration
    ) {
        self.catalog = catalog
        lookup = GnosticCatalogLookup(manager: manager, catalog: catalog, subscription: subscription, timeout: timeout)
        channel = GnosticCallChannel(manager: manager)
        self.timeout = timeout
    }

    /// Reads payload-free live diagnostics for the whole Node.
    ///
    /// - Parameter providerID: The expected provider that serves diagnostics,
    ///   or `nil` to resolve the single advertising provider from the session
    ///   catalog.
    /// - Returns: The payload-free node diagnostics snapshot.
    /// - Throws: ``GnosticDiagnosticsClientError`` when no provider advertises
    ///   ``GnosticCapability/diagnostics``, more than one does, or the serve
    ///   rejected the call.
    public func node(providerID: String? = nil) async throws -> NodeDiagnostics {
        let target = try await resolvedDiagnosticsProvider(providerID)
        return try await channel.call(
            DiagnosticsProvider.nodeOperation,
            request: DiagnosticsNodeRequest(),
            context: "diagnostics.node request",
            providerID: target,
            timeout: timeout,
            returning: NodeDiagnostics.self
        )
    }

    /// Reads payload-free live diagnostics for one Ascendant.
    ///
    /// - Parameters:
    ///   - ascendantID: The discovered Ascendant identifier.
    ///   - providerID: The expected provider that owns the Ascendant, or `nil`
    ///     to resolve it from the session catalog.
    /// - Returns: The payload-free Ascendant diagnostics snapshot.
    /// - Throws: ``GnosticDiagnosticsClientError`` when the Ascendant cannot be
    ///   resolved, its provider does not advertise
    ///   ``GnosticCapability/diagnostics``, or the serve rejected the call.
    public func ascendant(_ ascendantID: UUID, providerID: String? = nil) async throws -> AscendantDiagnostics {
        let entries = await lookup.entries(requiring: GnosticObjectType.ascendant, id: ascendantID)
        let target: String
        switch GnosticCatalogLookup.provider(
            of: GnosticObjectType.ascendant,
            id: ascendantID,
            in: entries,
            expected: providerID
        ) {
        case let .provider(providerID): target = providerID
        case .unavailable: throw GnosticDiagnosticsClientError.ascendantUnavailable(ascendantID)
        case .ambiguous: throw GnosticDiagnosticsClientError.ascendantAmbiguous(ascendantID)
        case .mismatch: throw GnosticDiagnosticsClientError.providerMismatch
        }
        guard GnosticCatalogLookup.ascendantAdvertises(
            GnosticCapability.diagnostics,
            ascendantID: ascendantID,
            providerID: target,
            in: entries
        ) else {
            throw GnosticDiagnosticsClientError.missingCapability(GnosticCapability.diagnostics)
        }
        return try await channel.call(
            DiagnosticsProvider.ascendantOperation,
            request: DiagnosticsTargetRequest(id: ascendantID),
            context: "diagnostics.ascendant request",
            providerID: target,
            timeout: timeout,
            returning: AscendantDiagnostics.self
        )
    }

    /// Reads payload-free live diagnostics for one Timeline.
    ///
    /// - Parameters:
    ///   - timelineID: The discovered Timeline identifier.
    ///   - providerID: The expected provider that owns the Timeline, or `nil`
    ///     to resolve it from the session catalog.
    /// - Returns: The payload-free Timeline diagnostics snapshot.
    /// - Throws: ``GnosticDiagnosticsClientError`` when the Timeline cannot be
    ///   resolved, its operating Ascendant does not advertise
    ///   ``GnosticCapability/diagnostics``, or the serve rejected the call.
    public func timeline(_ timelineID: UUID, providerID: String? = nil) async throws -> TimelineDiagnostics {
        let entries = await lookup.entries(requiring: GnosticObjectType.timeline, id: timelineID)
        let target: String
        switch GnosticCatalogLookup.provider(
            of: GnosticObjectType.timeline,
            id: timelineID,
            in: entries,
            expected: providerID
        ) {
        case let .provider(providerID): target = providerID
        case .unavailable: throw GnosticDiagnosticsClientError.timelineUnavailable(timelineID)
        case .ambiguous: throw GnosticDiagnosticsClientError.timelineAmbiguous(timelineID)
        case .mismatch: throw GnosticDiagnosticsClientError.providerMismatch
        }
        guard let ascendantID = GnosticCatalogLookup.operatingAscendantID(
            ofTimeline: timelineID,
            providerID: target,
            in: entries
        ), GnosticCatalogLookup.ascendantAdvertises(
            GnosticCapability.diagnostics,
            ascendantID: ascendantID,
            providerID: target,
            in: entries
        ) else {
            throw GnosticDiagnosticsClientError.missingCapability(GnosticCapability.diagnostics)
        }
        return try await channel.call(
            DiagnosticsProvider.timelineOperation,
            request: DiagnosticsTargetRequest(id: timelineID),
            context: "diagnostics.timeline request",
            providerID: target,
            timeout: timeout,
            returning: TimelineDiagnostics.self
        )
    }

    private func resolvedDiagnosticsProvider(_ explicitProviderID: String?) async throws -> String {
        var providers = GnosticCatalogLookup.providers(
            advertising: GnosticCapability.diagnostics,
            in: await catalog.networkObjects()
        )
        if providers.isEmpty {
            await lookup.refresh()
            providers = GnosticCatalogLookup.providers(
                advertising: GnosticCapability.diagnostics,
                in: await catalog.networkObjects()
            )
        }
        guard !providers.isEmpty else {
            throw GnosticDiagnosticsClientError.missingCapability(GnosticCapability.diagnostics)
        }
        if let explicitProviderID {
            guard let match = providers.first(where: {
                $0.caseInsensitiveCompare(explicitProviderID) == .orderedSame
            }) else {
                throw GnosticDiagnosticsClientError.nodeUnavailable
            }
            return match
        }
        guard providers.count == 1, let providerID = providers.first else {
            throw GnosticDiagnosticsClientError.nodeAmbiguous
        }
        return providerID
    }
}
