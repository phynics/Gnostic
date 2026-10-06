// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// An actor-backed in-memory store for accepted context nodes.
///
/// The store partitions by Ascendant and Timeline. It holds only accepted
/// nodes and bookkeeping. It never holds conversation history, so dropping the
/// store cannot affect the conversation.
///
/// The store is linear-Timeline only. It has no `branchHeadID`; branch-aware
/// coverage is an epic follow-up.
///
/// Durability is opt-in through ``enableDurability(at:)``. When enabled, the
/// store journals each mutation through the shared append-only log primitive,
/// so derived context state survives a restart. The journal persists derived
/// node bodies, not conversation transcripts.
public actor InMemoryContextStore {
    /// The per-partition state.
    private struct Partition {
        var nodes: [String: ContextNode] = [:]
        var checkpointCandidates: [String] = []
        var checkpoints: [String: ContextCheckpoint] = [:]
        var activeCheckpointID: String?
        var projectionRevision = 0
    }

    private var partitions: [ContextStoreKey: Partition] = [:]
    private var journal: AppendOnlyEventLog<ContextStoreEvent>?

    /// Creates an empty store.
    public init() {}

    /// Enables durable journaling at `url` and recovers the state already on
    /// disk.
    ///
    /// Call before the first mutation. Recovery replays the valid prefix of the
    /// journal through the store's own mutation path, so accepted nodes,
    /// checkpoint bookkeeping, and projection revisions are rebuilt exactly as
    /// they stood when the previous process stopped. A torn or corrupt tail is
    /// truncated by the log primitive. Journaling is off until this method is
    /// called.
    ///
    /// Live memory stays authoritative: each mutating call applies in memory
    /// first and only then appends to the journal, so a journal failure never
    /// corrupts accepted state.
    ///
    /// - Parameter url: The append-only journal file.
    /// - Throws: ``ContextError`` when a recorded mutation is invalid, or
    ///   `EventLogError` when the journal cannot be read or written.
    public func enableDurability(at url: URL) throws {
        let log = AppendOnlyEventLog<ContextStoreEvent>(fileURL: url)
        for envelope in try log.recover() {
            try apply(envelope.payload)
        }
        journal = log
    }

    private func apply(_ event: ContextStoreEvent) throws {
        switch event {
        case let .inserted(node, key):
            try insert(node, for: key)
        case let .checkpointCandidate(nodeID, key):
            try insertCheckpointCandidate(nodeID, for: key)
        case let .checkpointInserted(checkpoint, key):
            try insertCheckpoint(checkpoint, for: key)
        case let .activeCheckpoint(checkpointID, key):
            try setActiveCheckpoint(checkpointID, for: key)
        case let .projectionRevision(value, key):
            var partition = partitions[key] ?? Partition()
            partition.projectionRevision = value
            partitions[key] = partition
        case .removedAll:
            removeAll()
        }
    }

    private func journalRecord(_ event: ContextStoreEvent) throws {
        guard let journal else { return }
        try journal.append(event)
    }

    /// Inserts an accepted node.
    ///
    /// A duplicate node with an identical body is idempotent. A different body
    /// for the same content-addressed ID is a structured error.
    ///
    /// - Parameters:
    ///   - node: The node to insert.
    ///   - key: The Ascendant and Timeline partition.
    /// - Throws: ``ContextError/crossTimeline`` when the node names another
    ///   Timeline, ``ContextError/unknownSourceRange`` when the coverage is
    ///   empty, or ``ContextError/conflictingBody`` when the ID already maps to
    ///   a different body.
    public func insert(_ node: ContextNode, for key: ContextStoreKey) throws {
        guard node.timelineID == key.timelineID, node.coverage.timelineID == key.timelineID else {
            throw ContextError.crossTimeline
        }
        guard !node.coverage.messageIDs.isEmpty, !node.coverage.digest.isEmpty else {
            throw ContextError.unknownSourceRange
        }
        var partition = partitions[key] ?? Partition()
        if let existing = partition.nodes[node.id] {
            guard existing.hasSameBody(as: node) else { throw ContextError.conflictingBody }
            return
        }
        partition.nodes[node.id] = node
        partitions[key] = partition
        try journalRecord(.inserted(node, key))
    }

    /// Returns one accepted node.
    ///
    /// - Parameters:
    ///   - id: The node ID.
    ///   - key: The partition.
    /// - Returns: The node, or `nil`.
    public func node(id: String, for key: ContextStoreKey) -> ContextNode? {
        partitions[key]?.nodes[id]
    }

    /// Whether the partition holds a node.
    ///
    /// - Parameters:
    ///   - id: The node ID.
    ///   - key: The partition.
    /// - Returns: Whether the node exists.
    public func contains(nodeID id: String, for key: ContextStoreKey) -> Bool {
        partitions[key]?.nodes[id] != nil
    }

    /// Returns every accepted node, ordered by first covered message.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The accepted nodes.
    public func acceptedNodes(for key: ContextStoreKey) -> [ContextNode] {
        guard let nodes = partitions[key]?.nodes.values else { return [] }
        return nodes.sorted { lhs, rhs in
            (lhs.coverage.firstMessageID ?? "") < (rhs.coverage.firstMessageID ?? "")
        }
    }

    /// Returns the root node IDs, ordered by first covered message.
    ///
    /// A root is a node no other node names as a child. The roots form the
    /// top of the hierarchy.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The root node IDs.
    public func rootNodeIDs(for key: ContextStoreKey) -> [String] {
        guard let partition = partitions[key] else { return [] }
        let childIDs = Set(partition.nodes.values.flatMap(\.children))
        return partition.nodes.values
            .filter { !childIDs.contains($0.id) }
            .sorted { ($0.coverage.firstMessageID ?? "") < ($1.coverage.firstMessageID ?? "") }
            .map(\.id)
    }

    /// Marks a node as a checkpoint candidate.
    ///
    /// A duplicate candidate is idempotent.
    ///
    /// - Parameters:
    ///   - nodeID: The candidate node ID.
    ///   - key: The partition.
    /// - Throws: ``ContextError/unknownSourceRange`` when the node does not exist.
    public func insertCheckpointCandidate(_ nodeID: String, for key: ContextStoreKey) throws {
        guard partitions[key]?.nodes[nodeID] != nil else { throw ContextError.unknownSourceRange }
        var partition = partitions[key] ?? Partition()
        guard !partition.checkpointCandidates.contains(nodeID) else { return }
        partition.checkpointCandidates.append(nodeID)
        partitions[key] = partition
        try journalRecord(.checkpointCandidate(nodeID, key))
    }

    /// Returns the checkpoint candidate node IDs, in insertion order.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The candidate node IDs.
    public func checkpointCandidates(for key: ContextStoreKey) -> [String] {
        partitions[key]?.checkpointCandidates ?? []
    }

    /// Inserts one accepted checkpoint.
    ///
    /// A duplicate checkpoint with an identical body is idempotent. A different
    /// body for the same content-addressed ID is a structured error.
    ///
    /// - Parameters:
    ///   - checkpoint: The checkpoint to insert.
    ///   - key: The Ascendant and Timeline partition.
    /// - Throws: ``ContextError/crossTimeline`` when the checkpoint names another
    ///   Timeline, or ``ContextError/conflictingBody`` when the ID already maps
    ///   to a different body.
    public func insertCheckpoint(_ checkpoint: ContextCheckpoint, for key: ContextStoreKey) throws {
        guard checkpoint.timelineID == key.timelineID,
              checkpoint.sourceRange.timelineID == key.timelineID
        else {
            throw ContextError.crossTimeline
        }
        var partition = partitions[key] ?? Partition()
        if let existing = partition.checkpoints[checkpoint.id] {
            guard existing == checkpoint else { throw ContextError.conflictingBody }
            return
        }
        partition.checkpoints[checkpoint.id] = checkpoint
        partitions[key] = partition
        try journalRecord(.checkpointInserted(checkpoint, key))
    }

    /// Returns one accepted checkpoint.
    ///
    /// - Parameters:
    ///   - id: The checkpoint ID.
    ///   - key: The partition.
    /// - Returns: The checkpoint, or `nil`.
    public func checkpoint(id: String, for key: ContextStoreKey) -> ContextCheckpoint? {
        partitions[key]?.checkpoints[id]
    }

    /// Sets the active checkpoint.
    ///
    /// - Parameters:
    ///   - checkpointID: The checkpoint ID, or `nil` to clear it.
    ///   - key: The partition.
    /// - Throws: ``ContextError/unknownSourceRange`` when the checkpoint does not exist.
    public func setActiveCheckpoint(_ checkpointID: String?, for key: ContextStoreKey) throws {
        if let checkpointID, partitions[key]?.checkpoints[checkpointID] == nil {
            throw ContextError.unknownSourceRange
        }
        var partition = partitions[key] ?? Partition()
        partition.activeCheckpointID = checkpointID
        partitions[key] = partition
        try journalRecord(.activeCheckpoint(checkpointID, key))
    }

    /// Returns the active checkpoint ID.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The active checkpoint ID, or `nil`.
    public func activeCheckpointID(for key: ContextStoreKey) -> String? {
        partitions[key]?.activeCheckpointID
    }

    /// Returns the active checkpoint.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The active checkpoint, or `nil`.
    public func activeCheckpoint(for key: ContextStoreKey) -> ContextCheckpoint? {
        guard let partition = partitions[key], let id = partition.activeCheckpointID else { return nil }
        return partition.checkpoints[id]
    }

    /// Advances the projection revision by one and returns the new value.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The new projection revision.
    @discardableResult
    public func advanceProjectionRevision(for key: ContextStoreKey) -> Int {
        var partition = partitions[key] ?? Partition()
        partition.projectionRevision += 1
        partitions[key] = partition
        try? journalRecord(.projectionRevision(partition.projectionRevision, key))
        return partition.projectionRevision
    }

    /// Returns the current projection revision.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The projection revision.
    public func projectionRevision(for key: ContextStoreKey) -> Int {
        partitions[key]?.projectionRevision ?? 0
    }

    /// Removes every partition.
    ///
    /// Dropping the store's contents cannot affect conversation history because
    /// the store never held it.
    public func removeAll() {
        partitions.removeAll()
        try? journalRecord(.removedAll)
    }
}
