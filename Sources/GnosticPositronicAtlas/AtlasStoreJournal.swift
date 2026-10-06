// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// One durable mutation of an ``InMemoryAtlasStore``.
///
/// Each case records the input of a mutation after the store applied it in
/// memory. Replaying the recorded inputs through the store's own mutation path
/// rebuilds the same registrations, report log, accepted state, and accepted
/// history. The payload is Gnostic-owned so the kernel log primitive stays
/// free of Atlas types.
public enum AtlasStoreEvent: Codable, Sendable, Equatable {
    /// A Shard registration was inserted.
    case registered(AscendantShard)
    /// A report was appended and assigned its per-Shard sequence.
    case appended(AscendantShardReport)
    /// A patch was accepted against an integration capture.
    case accepted(AtlasPatch)
}
