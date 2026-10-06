// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// One durable mutation of an ``InMemoryContextStore``.
///
/// Each case records the input of a mutation after the store applied it in
/// memory. Replaying the recorded inputs through the store's own mutation path
/// rebuilds the same partitions, checkpoint bookkeeping, and projection
/// revisions. The payload is Gnostic-owned so the kernel log primitive stays
/// free of Context types.
public enum ContextStoreEvent: Codable, Sendable, Equatable {
    /// An accepted node was inserted into a partition.
    case inserted(ContextNode, ContextStoreKey)
    /// A node was marked as a checkpoint candidate.
    case checkpointCandidate(String, ContextStoreKey)
    /// An accepted checkpoint was inserted into a partition.
    case checkpointInserted(ContextCheckpoint, ContextStoreKey)
    /// The active checkpoint was set or cleared.
    case activeCheckpoint(String?, ContextStoreKey)
    /// The projection revision was set to an absolute value.
    case projectionRevision(Int, ContextStoreKey)
    /// Every partition was removed.
    case removedAll
}
