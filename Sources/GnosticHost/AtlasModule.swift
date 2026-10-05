// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticPositronicAtlas
import PositronicKit

/// The compiled-in Atlas continuity module.
///
/// Atlas is selected per Ascendant through the backend-owned `extensions`
/// setting (`"extensions": ["atlas"]`). One selection installs both halves of
/// one correlated ``AtlasTurnIntegration``:
///
/// - the Positronic Turn context source that projects the bounded Ascendant
///   Brief into the prompt, and
/// - the terminal Turn observer that records one Shard Report per terminal
///   Turn.
///
/// The two halves share one in-memory store and correlator per Ascendant, built
/// lazily on first use because the store's Shard registration is
/// actor-isolated. The store is ephemeral by design: this slice proves the
/// module system wires Atlas end to end, and a durable store replaces the
/// injected factory without changing the descriptor.
enum AtlasModule {
    /// The production descriptor over the in-memory store.
    static let value = make(storeFactory: { ascendant in
        InMemoryAtlasStore(ascendantID: ascendant.id)
    })

    /// Builds the Atlas descriptor over an injected store factory.
    ///
    /// - Parameter storeFactory: Creates the store for one Ascendant. The
    ///   production composition injects ``InMemoryAtlasStore``; a test injects
    ///   a recorder so it can inspect the state the module wrote.
    /// - Returns: The Atlas module descriptor.
    static func make(
        storeFactory: @escaping @Sendable (NodeManifest.Ascendant) -> any AtlasStore
    ) -> GnosticModule {
        let runtime = AtlasModuleRuntime(storeFactory: storeFactory)
        return GnosticModule(
            name: "atlas",
            registryID: "GNO-MOD-ATLAS",
            terminalTurnObservers: [{ scope in
                AtlasModuleObserver(runtime: runtime, scope: scope)
            }],
            contribution: { scope in
                AtlasModuleContribution(runtime: runtime, scope: scope)
            }
        )
    }
}

/// The lazy, per-Ascendant Atlas integration registry.
///
/// The module's observer and contribution factories are synchronous, but the
/// store must register a Shard before Atlas can append a report, and Shard
/// registration is actor-isolated. This actor defers that work to first use and
/// caches one shared ``AtlasTurnIntegration`` per Ascendant, so the context
/// source and the recorder always correlate through the same store and
/// correlator.
actor AtlasModuleRuntime {
    private let storeFactory: @Sendable (NodeManifest.Ascendant) -> any AtlasStore
    private var integrations: [UUID: AtlasTurnIntegration] = [:]

    init(storeFactory: @escaping @Sendable (NodeManifest.Ascendant) -> any AtlasStore) {
        self.storeFactory = storeFactory
    }

    /// Returns the integration for one Ascendant, building it on first use.
    ///
    /// The module registers one home Shard per Ascendant. The Shard identity is
    /// the Ascendant identity: the module owns exactly one context, the store is
    /// per-process, and a durable store that allocates distinct Shards can widen
    /// this later without changing the descriptor.
    ///
    /// - Parameter scope: The Ascendant that selected Atlas.
    /// - Returns: The shared integration for the Ascendant.
    /// - Throws: ``AtlasStoreError`` when the Shard registration is rejected.
    func integration(for scope: GnosticModuleScope) async throws -> AtlasTurnIntegration {
        let ascendant = scope.ascendant
        if let existing = integrations[ascendant.id] { return existing }

        let store = storeFactory(ascendant)
        let shardID = AscendantShardID(ascendant.id)
        _ = try await store.register(AscendantShard(
            id: shardID,
            ascendantID: ascendant.id,
            name: ascendant.name,
            kind: .home
        ))
        let integration = AtlasTurnIntegration(store: store, shardID: shardID)
        integrations[ascendant.id] = integration
        return integration
    }
}

/// The Atlas descriptor's Positronic contribution.
///
/// Building the contribution is synchronous, so the store stays lazy until the
/// context source first runs.
private struct AtlasModuleContribution: PositronicContribution {
    let label = AtlasTurnContribution.defaultLabel
    let runtime: AtlasModuleRuntime
    let scope: GnosticModuleScope

    func turnContextSource() -> (any TurnContextSource)? {
        AtlasModuleTurnContextSource(runtime: runtime, scope: scope)
    }
}

/// The descriptor's deferred Atlas Turn context source.
private struct AtlasModuleTurnContextSource: TurnContextSource {
    let runtime: AtlasModuleRuntime
    let scope: GnosticModuleScope

    /// Atlas context is additive: a missing or failed projection never fails a Turn.
    var failureRequirement: TurnContextContributionRequirement { .optional }

    func contributions(for request: TurnContextRequest) async throws -> [TurnContextContribution] {
        let integration = try await runtime.integration(for: scope)
        guard let source = integration.contribution.turnContextSource() else { return [] }
        return try await source.contributions(for: request)
    }
}

/// The descriptor's deferred Atlas Shard Report recorder.
private struct AtlasModuleObserver: TerminalTurnObserving {
    let runtime: AtlasModuleRuntime
    let scope: GnosticModuleScope

    func observe(_ record: TerminalTurnRecord) async throws {
        let integration = try await runtime.integration(for: scope)
        try await integration.observer.observe(record)
    }
}
