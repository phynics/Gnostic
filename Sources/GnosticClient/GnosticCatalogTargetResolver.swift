// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol

/// The catalogued object kinds a consumer client addresses by identifier.
enum CatalogTargetKind: Sendable, Equatable {
    /// A Runtime instance, which operates itself.
    case runtimeInstance
    /// A Timeline, whose operating Runtime instance the catalog names.
    case timeline

    var objectType: String {
        switch self {
        case .runtimeInstance: GnosticObjectType.runtimeInstance
        case .timeline: GnosticObjectType.timeline
        }
    }
}

/// A catalog target resolved to the provider that serves it.
struct CatalogTarget: Sendable, Equatable {
    /// The provider that advertised the target, spelled as the catalog spells it.
    let providerID: String

    /// The Runtime instance that operates the target, when a capability was
    /// required. It is `nil` when no capability was required.
    let runtimeInstanceID: UUID?
}

/// The one failure set every consumer client maps to its own public error.
///
/// Each client converts these cases in exactly one mapping function, so the
/// public error vocabulary stays per client while the decision logic lives in
/// ``CatalogTargetResolver`` alone.
enum CatalogTargetFailure: Error, Sendable, Equatable {
    /// No live provider advertises the target, or a Timeline names no single
    /// operating identity when a capability is required.
    case unavailable

    /// More than one provider advertises the target.
    case ambiguous

    /// The expected provider does not own the target.
    case providerMismatch

    /// The operating Runtime instance does not provide the required capability.
    case missingCapability(String)
}

/// Resolves consumer call targets from the session catalog under one policy.
///
/// ## Policy
///
/// - **Refresh.** The catalog is refreshed at most once per resolution, and
///   only when the target is absent. For an object, absent means no advertised
///   object of its kind and identifier, so an unavailable object is absent. For
///   a provider-level target, absent means no provider advertises a Runtime
///   instance. Capability and operating-instance checks read the catalog as it
///   stands and never trigger a refresh; after the refresh, the resolution
///   fails.
/// - **Ambiguity.** More than one provider advertising the target is
///   ``CatalogTargetFailure/ambiguous``.
/// - **Expected provider.** When an expected provider is supplied and does not
///   own the object, the result is ``CatalogTargetFailure/providerMismatch``.
///   For a provider-level target, an expected provider outside the advertising
///   set is ``CatalogTargetFailure/unavailable``, because no node-wide target
///   can be mismatched against an object.
/// - **Capability.** A Runtime instance advertises no capability list. It
///   provides the names in ``GnosticCapability/providedByRuntimeInstance`` by
///   being advertised: ACP v2 requires `session/prompt`, and the Node that
///   hosts the instance owns Timeline management and diagnostics. A required
///   capability is therefore checked as "the operating Runtime instance is
///   advertised by the resolved provider". For a Timeline the operating
///   instance is the one the Timeline names; a Timeline without exactly one is
///   ``CatalogTargetFailure/unavailable``. A name outside that set is
///   ``CatalogTargetFailure/missingCapability(_:)``.
///
/// The resolver owns no public error type. It ships no wire call.
@MainActor
struct CatalogTargetResolver {
    let lookup: GnosticCatalogLookup

    /// Resolves one object target to its provider and, when a capability is
    /// required, to its operating Runtime instance.
    ///
    /// - Parameters:
    ///   - kind: The object kind addressed by `id`.
    ///   - id: The object identifier.
    ///   - expectedProviderID: The provider the caller pinned, or `nil`.
    ///   - requiredCapability: The capability the operating Runtime instance
    ///     must provide, or `nil` when none is required.
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

    /// Resolves the single provider that provides a node-wide capability,
    /// such as live diagnostics.
    ///
    /// - Parameters:
    ///   - capability: The capability a Runtime instance of the provider must
    ///     provide.
    ///   - expectedProviderID: The provider the caller pinned, or `nil`.
    /// - Returns: The resolved provider, or the one failure the client maps.
    ///   An absent capability is ``CatalogTargetFailure/missingCapability(_:)``.
    func resolveProvider(
        providing capability: String,
        expectedProviderID: String? = nil
    ) async -> Result<CatalogTarget, CatalogTargetFailure> {
        var providers = GnosticCatalogLookup.providers(
            providing: capability,
            in: await lookup.catalog.networkObjects()
        )
        if providers.isEmpty {
            await lookup.refresh()
            providers = GnosticCatalogLookup.providers(
                providing: capability,
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
            return .success(CatalogTarget(providerID: match, runtimeInstanceID: nil))
        }
        guard providers.count == 1, let providerID = providers.first else {
            return .failure(.ambiguous)
        }
        return .success(CatalogTarget(providerID: providerID, runtimeInstanceID: nil))
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
            return .success(CatalogTarget(providerID: providerID, runtimeInstanceID: nil))
        }
        let runtimeInstanceID: UUID
        switch kind {
        case .runtimeInstance:
            runtimeInstanceID = id
        case .timeline:
            guard let operating = GnosticCatalogLookup.runtimeInstanceID(
                ofTimeline: id,
                providerID: providerID,
                in: entries
            ) else {
                return .failure(.unavailable)
            }
            runtimeInstanceID = operating
        }
        guard GnosticCatalogLookup.runtimeInstanceProvides(
            requiredCapability,
            runtimeInstanceID: runtimeInstanceID,
            providerID: providerID,
            in: entries
        ) else {
            return .failure(.missingCapability(requiredCapability))
        }
        return .success(CatalogTarget(providerID: providerID, runtimeInstanceID: runtimeInstanceID))
    }
}
