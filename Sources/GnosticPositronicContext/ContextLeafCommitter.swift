// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Validates a leaf proposal and commits it to the store.
///
/// The committer is the only path from a proposal to an accepted node. It
/// validates first, then inserts. Insertion is idempotent because the node ID is
/// content-addressed, so committing the same proposal twice accepts one node.
public actor ContextLeafCommitter {
    /// The store the committer writes to.
    public let store: InMemoryContextStore
    /// The validator the committer uses.
    public let validator: ContextProposalValidator

    /// Creates a committer.
    ///
    /// - Parameters:
    ///   - store: The store.
    ///   - validator: The validator.
    public init(store: InMemoryContextStore, validator: ContextProposalValidator) {
        self.store = store
        self.validator = validator
    }

    /// Validates and commits one leaf proposal.
    ///
    /// - Parameters:
    ///   - leaf: The proposal and the episode it covers.
    ///   - key: The Ascendant and Timeline partition.
    ///   - activeCarry: The carry already accepted for the Timeline.
    /// - Returns: The accepted node.
    /// - Throws: A `ContextError` when validation fails, or when the store
    ///   finds a conflicting body for the same ID.
    @discardableResult
    public func commit(
        _ leaf: ContextLeafProposal,
        for key: ContextStoreKey,
        activeCarry: ContextCarryState
    ) async throws -> ContextNode {
        let node = try validator.validate(leaf, expectedTimelineID: key.timelineID, activeCarry: activeCarry)
        try await store.insert(node, for: key)
        return node
    }
}
