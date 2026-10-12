// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol

/// The catalogued object kinds a consumer client addresses by identifier.
enum CatalogTargetKind: Sendable, Equatable {
    /// An Ascendant, which operates itself.
    case ascendant
    /// A Timeline, whose operating Ascendant the catalog names.
    case timeline

    var objectType: String {
        switch self {
        case .ascendant: GnosticObjectType.ascendant
        case .timeline: GnosticObjectType.timeline
        }
    }
}

/// A catalog target resolved to the provider that serves it.
struct CatalogTarget: Sendable, Equatable {
    /// The provider that advertised the target, spelled as the catalog spells it.
    let providerID: String

    /// The Ascendant that operates the target, when a capability was required.
    /// It is the target itself for an Ascendant and the operating Ascendant for
    /// a Timeline; it is `nil` when no capability was required.
    let ascendantID: UUID?
}

/// The one failure set every consumer client maps to its own public error.
///
/// Each client converts these cases in exactly one mapping function, so the
/// public error vocabulary stays per client while the decision logic lives in
/// ``CatalogTargetResolver`` alone.
enum CatalogTargetFailure: Error, Sendable, Equatable {
    /// No live provider advertises the target, or a Timeline names no single
    /// operating Ascendant when a capability is required.
    case unavailable

    /// More than one provider advertises the target.
    case ambiguous

    /// The expected provider does not own the target.
    case providerMismatch

    /// The operating Ascendant does not advertise the required capability.
    case missingCapability(String)
}

/// Resolves consumer call targets from the session catalog under one policy.
///
/// ## Policy
///
/// - **Refresh.** The catalog is refreshed at most once per resolution, and
///   only when the target is absent. For an object, absent means no advertised
///   object of its kind and identifier, so an unavailable object is absent. For
///   a provider-level target, absent means no provider advertises the
///   capability. Capability and operating-Ascendant checks read the catalog as
///   it stands and never trigger a refresh; after the refresh, the resolution
///   fails.
/// - **Ambiguity.** More than one provider advertising the target is
///   ``CatalogTargetFailure/ambiguous``.
/// - **Expected provider.** When an expected provider is supplied and does not
///   own the object, the result is ``CatalogTargetFailure/providerMismatch``.
///   For a provider-level target, an expected provider outside the advertising
///   set is ``CatalogTargetFailure/unavailable``, because no node-wide target
///   can be mismatched against an object.
/// - **Capability.** A required capability is checked on the operating
///   Ascendant of the resolved provider. A Timeline without exactly one
///   operating Ascendant is ``CatalogTargetFailure/unavailable`` because there is
///   no Ascendant to gate against.
///
/// The resolver owns no public error type. It ships no wire call.
@MainActor
struct CatalogTargetResolver {
    let lookup: GnosticCatalogLookup

    /// Resolves one object target to its provider and, when a capability is
    /// required, to its operating Ascendant.
    ///
    /// - Parameters:
    ///   - kind: The object kind addressed by `id`.
    ///   - id: The object identifier.
    ///   - expectedProviderID: The provider the caller pinned, or `nil`.
    ///   - requiredCapability: The capability the operating Ascendant must
    ///     advertise, or `nil` when none is required.
    /// - Returns: The resolved target, or the one failure the client maps.
    func resolve(
        _ kind: CatalogTargetKind,
        id: UUID,
        expectedProviderID: String? = nil,
        requiredCapability: String? = nil
    ) async -> Result<CatalogTarget, CatalogTargetFailure> {
        let entries = await lookup.entries(requiring: kind.objectType, id: id)
        return Self.target(
            kind,
            id: id,
            expectedProviderID: expectedProviderID,
            requiredCapability: requiredCapability,
            in: entries
        )
    }

    /// Resolves the single provider that advertises a node-wide capability,
    /// such as live diagnostics.
    ///
    /// - Parameters:
    ///   - capability: The capability any Ascendant of the provider must advertise.
    ///   - expectedProviderID: The provider the caller pinned, or `nil`.
    /// - Returns: The resolved provider, or the one failure the client maps.
    ///   An absent capability is ``CatalogTargetFailure/missingCapability(_:)``.
    func resolveProvider(
        advertising capability: String,
        expectedProviderID: String? = nil
    ) async -> Result<CatalogTarget, CatalogTargetFailure> {
        var providers = GnosticCatalogLookup.providers(
            advertising: capability,
            in: await lookup.catalog.networkObjects()
        )
        if providers.isEmpty {
            await lookup.refresh()
            providers = GnosticCatalogLookup.providers(
                advertising: capability,
                in: await lookup.catalog.networkObjects()
            )
        }
        guard !providers.isEmpty else {
            return .failure(.missingCapability(capability))
        }
        if let expectedProviderID {
            guard let match = providers.first(where: {
                $0.caseInsensitiveCompare(expectedProviderID) == .orderedSame
            }) else {
                return .failure(.unavailable)
            }
            return .success(CatalogTarget(providerID: match, ascendantID: nil))
        }
        guard providers.count == 1, let providerID = providers.first else {
            return .failure(.ambiguous)
        }
        return .success(CatalogTarget(providerID: providerID, ascendantID: nil))
    }

    /// Reports whether any Ascendant of a provider advertises a capability,
    /// read from the catalog without a refresh.
    func providerAdvertises(_ capability: String, providerID: String) async -> Bool {
        GnosticCatalogLookup.ascendantAdvertises(
            capability,
            providerID: providerID,
            in: await lookup.catalog.networkObjects()
        )
    }

    /// Applies the resolution rules to a catalog snapshot. Pure, so the policy
    /// is testable without a broker.
    static func target(
        _ kind: CatalogTargetKind,
        id: UUID,
        expectedProviderID: String?,
        requiredCapability: String?,
        in entries: [NetworkCatalogEntry]
    ) -> Result<CatalogTarget, CatalogTargetFailure> {
        let providerID: String
        switch GnosticCatalogLookup.provider(
            of: kind.objectType,
            id: id,
            in: entries,
            expected: expectedProviderID
        ) {
        case let .provider(resolved): providerID = resolved
        case .unavailable: return .failure(.unavailable)
        case .ambiguous: return .failure(.ambiguous)
        case .mismatch: return .failure(.providerMismatch)
        }
        guard let requiredCapability else {
            return .success(CatalogTarget(providerID: providerID, ascendantID: nil))
        }
        let ascendantID: UUID
        switch kind {
        case .ascendant:
            ascendantID = id
        case .timeline:
            guard let operating = GnosticCatalogLookup.operatingAscendantID(
                ofTimeline: id,
                providerID: providerID,
                in: entries
            ) else {
                return .failure(.unavailable)
            }
            ascendantID = operating
        }
        guard GnosticCatalogLookup.ascendantAdvertises(
            requiredCapability,
            ascendantID: ascendantID,
            providerID: providerID,
            in: entries
        ) else {
            return .failure(.missingCapability(requiredCapability))
        }
        return .success(CatalogTarget(providerID: providerID, ascendantID: ascendantID))
    }
}
