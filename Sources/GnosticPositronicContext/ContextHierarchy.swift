// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A chronological summary hierarchy over accepted leaf nodes.
///
/// Level zero holds the leaves. Each higher level holds the parents of the level
/// below. A parent covers the exact contiguous source range of its children, so
/// the tree has no coverage gaps and no overlaps. Topic labels never decide
/// coverage.
public struct ContextHierarchy: Sendable, Equatable {
    /// The levels of the tree. Level zero is the leaves; the last level holds
    /// the roots.
    public let levels: [[ContextNode]]

    /// Creates a hierarchy.
    ///
    /// - Parameter levels: The levels, bottom-up.
    public init(levels: [[ContextNode]]) {
        self.levels = levels
    }

    /// The leaf nodes, in chronological order.
    public var leaves: [ContextNode] {
        levels.first ?? []
    }

    /// The root node, when the hierarchy is not empty.
    public var root: ContextNode? {
        levels.last?.first
    }

    /// Every node in the tree, bottom-up.
    public var nodes: [ContextNode] {
        levels.flatMap { $0 }
    }

    /// The root node IDs.
    public var rootIDs: [String] {
        levels.last?.map(\.id) ?? []
    }
}

/// Builds a chronological hierarchy from accepted leaf nodes.
///
/// The builder is pure and deterministic. It groups contiguous leaves into
/// parents whose fan-out stays within the descriptor bounds, then repeats until
/// one root remains. Rebuilding from the same leaves gives an equivalent tree.
public struct ContextHierarchyBuilder: Sendable {
    /// The host-owned bounds, including the fan-out range.
    public let descriptor: ContextDescriptor
    /// The carry reducer.
    public let reducer: ContextCarryReducer

    /// Creates a builder.
    ///
    /// - Parameters:
    ///   - descriptor: The host-owned bounds.
    ///   - reducer: The carry reducer.
    public init(descriptor: ContextDescriptor = .default, reducer: ContextCarryReducer = ContextCarryReducer()) {
        self.descriptor = descriptor
        self.reducer = reducer
    }

    /// Builds the hierarchy.
    ///
    /// - Parameters:
    ///   - leaves: The accepted leaf nodes, in chronological order.
    ///   - timelineID: The Timeline the leaves belong to.
    /// - Returns: The hierarchy.
    public func build(leaves: [ContextNode], timelineID: String) -> ContextHierarchy {
        guard !leaves.isEmpty else { return ContextHierarchy(levels: []) }
        var levels: [[ContextNode]] = [leaves]
        var current = leaves
        while current.count > 1 {
            let parents = chunkRanges(current.count).map { range in
                makeParent(Array(current[range]), timelineID: timelineID)
            }
            levels.append(parents)
            current = parents
        }
        return ContextHierarchy(levels: levels)
    }

    /// Splits a level into contiguous ranges whose sizes respect the fan-out.
    ///
    /// - Parameter count: The number of nodes in the level.
    /// - Returns: The contiguous ranges.
    func chunkRanges(_ count: Int) -> [Range<Int>] {
        guard count > descriptor.maximumFanOut else { return [0..<count] }
        var groups = (count + descriptor.maximumFanOut - 1) / descriptor.maximumFanOut
        while groups < count, count / groups < descriptor.minimumFanOut {
            groups += 1
        }
        let base = count / groups
        let remainder = count % groups
        var ranges: [Range<Int>] = []
        var start = 0
        for index in 0..<groups {
            let size = base + (index < remainder ? 1 : 0)
            let end = min(start + size, count)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// Builds one parent node over the given children.
    ///
    /// - Parameters:
    ///   - children: The children, in chronological order.
    ///   - timelineID: The Timeline the children belong to.
    /// - Returns: The parent node.
    func makeParent(_ children: [ContextNode], timelineID: String) -> ContextNode {
        let coverage = ContextSourceRange.hostComputed(
            timelineID: timelineID,
            messageIDs: Self.unionMessageIDs(children.map(\.coverage))
        )
        return ContextNode(
            timelineID: timelineID,
            coverage: coverage,
            children: children.map(\.id),
            synopsis: nil,
            carry: reducer.reduce(children.map(\.carry)),
            curatorVersion: "hierarchy-v1"
        )
    }

    /// Unions coverage ranges into one chronological, de-duplicated message list.
    ///
    /// - Parameter ranges: The ranges to union.
    /// - Returns: The unioned message IDs, in chronological order.
    static func unionMessageIDs(_ ranges: [ContextSourceRange]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for range in ranges {
            for id in range.messageIDs where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result.sorted()
    }
}
