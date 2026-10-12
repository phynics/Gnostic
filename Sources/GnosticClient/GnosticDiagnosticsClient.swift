// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
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
    private let resolver: CatalogTargetResolver
    private let channel: GnosticCallChannel<GnosticDiagnosticsClientError>
    private let timeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration
    ) {
        self.catalog = catalog
        resolver = CatalogTargetResolver(lookup: GnosticCatalogLookup(
            manager: manager,
            catalog: catalog,
            subscription: subscription,
            timeout: timeout
        ))
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
        let target: CatalogTarget
        switch await resolver.resolve(
            .ascendant,
            id: ascendantID,
            expectedProviderID: providerID,
            requiredCapability: GnosticCapability.diagnostics
        ) {
        case let .success(resolved): target = resolved
        case let .failure(failure): throw Self.error(for: failure, ascendant: ascendantID)
        }
        return try await channel.call(
            DiagnosticsProvider.ascendantOperation,
            request: DiagnosticsTargetRequest(id: ascendantID),
            context: "diagnostics.ascendant request",
            providerID: target.providerID,
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
    ///   resolved or names no operating Ascendant (`timelineUnavailable`), its
    ///   operating Ascendant does not advertise
    ///   ``GnosticCapability/diagnostics`` (`missingCapability`), or the serve
    ///   rejected the call.
    public func timeline(_ timelineID: UUID, providerID: String? = nil) async throws -> TimelineDiagnostics {
        let target: CatalogTarget
        switch await resolver.resolve(
            .timeline,
            id: timelineID,
            expectedProviderID: providerID,
            requiredCapability: GnosticCapability.diagnostics
        ) {
        case let .success(resolved): target = resolved
        case let .failure(failure): throw Self.error(for: failure, timeline: timelineID)
        }
        return try await channel.call(
            DiagnosticsProvider.timelineOperation,
            request: DiagnosticsTargetRequest(id: timelineID),
            context: "diagnostics.timeline request",
            providerID: target.providerID,
            timeout: timeout,
            returning: TimelineDiagnostics.self
        )
    }

    /// Resolves the node-wide diagnostics provider. An explicit provider that
    /// does not serve diagnostics is ``GnosticDiagnosticsClientError/nodeUnavailable``
    /// rather than ``GnosticDiagnosticsClientError/providerMismatch``: no
    /// object is addressed, so there is no ownership to mismatch.
    private func resolvedDiagnosticsProvider(_ explicitProviderID: String?) async throws -> String {
        switch await resolver.resolveProvider(
            advertising: GnosticCapability.diagnostics,
            expectedProviderID: explicitProviderID
        ) {
        case let .success(target): return target.providerID
        case let .failure(failure): throw Self.nodeError(for: failure)
        }
    }

    /// The one mapping from catalog target failures to diagnostics client errors
    /// addressed by Ascendant.
    static func error(for failure: CatalogTargetFailure, ascendant ascendantID: UUID) -> GnosticDiagnosticsClientError {
        switch failure {
        case .unavailable: .ascendantUnavailable(ascendantID)
        case .ambiguous: .ascendantAmbiguous(ascendantID)
        case .providerMismatch: .providerMismatch
        case let .missingCapability(capability): .missingCapability(capability)
        }
    }

    /// The one mapping from catalog target failures to diagnostics client errors
    /// addressed by Timeline.
    static func error(for failure: CatalogTargetFailure, timeline timelineID: UUID) -> GnosticDiagnosticsClientError {
        switch failure {
        case .unavailable: .timelineUnavailable(timelineID)
        case .ambiguous: .timelineAmbiguous(timelineID)
        case .providerMismatch: .providerMismatch
        case let .missingCapability(capability): .missingCapability(capability)
        }
    }

    /// The one mapping from node-wide catalog target failures to diagnostics
    /// client errors.
    static func nodeError(for failure: CatalogTargetFailure) -> GnosticDiagnosticsClientError {
        switch failure {
        case .unavailable: .nodeUnavailable
        case .ambiguous: .nodeAmbiguous
        case .providerMismatch: .providerMismatch
        case let .missingCapability(capability): .missingCapability(capability)
        }
    }
}
