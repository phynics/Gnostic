// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// An actor-backed in-memory store for accepted context nodes.
///
/// The store partitions by Ascendant and Timeline. It holds only accepted
/// nodes and bookkeeping. It never holds conversation history, so dropping the
/// store cannot affect the conversation.
///
/// The store is linear-Timeline only. It has no `branchHeadID`; branch-aware
/// coverage is an epic follow-up.
public actor InMemoryContextStore {
    /// The per-partition state.
    private struct Partition {
        var nodes: [String: ContextNode] = [:]
        var checkpointCandidates: [String] = []
        var activeCheckpointID: String?
        var projectionRevision = 0
    }

    private var partitions: [ContextStoreKey: Partition] = [:]

    /// Creates an empty store.
    public init() {}

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
    }

    /// Returns the checkpoint candidate node IDs, in insertion order.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The candidate node IDs.
    public func checkpointCandidates(for key: ContextStoreKey) -> [String] {
        partitions[key]?.checkpointCandidates ?? []
    }

    /// Sets the active checkpoint.
    ///
    /// - Parameters:
    ///   - nodeID: The checkpoint node ID, or `nil` to clear it.
    ///   - key: The partition.
    /// - Throws: ``ContextError/unknownSourceRange`` when the node does not exist.
    public func setActiveCheckpoint(_ nodeID: String?, for key: ContextStoreKey) throws {
        if let nodeID, partitions[key]?.nodes[nodeID] == nil {
            throw ContextError.unknownSourceRange
        }
        var partition = partitions[key] ?? Partition()
        partition.activeCheckpointID = nodeID
        partitions[key] = partition
    }

    /// Returns the active checkpoint node ID.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The active checkpoint node ID, or `nil`.
    public func activeCheckpoint(for key: ContextStoreKey) -> String? {
        partitions[key]?.activeCheckpointID
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
    }
}
