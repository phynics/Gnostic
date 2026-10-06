// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Reduces the carry of several child nodes into one deterministic parent carry.
///
/// The reducer deduplicates goals and constraints, applies supersession, drops
/// resolved questions from the active set, keeps historical provenance, and
/// unions exact pins. An item is dropped from the active set only when another
/// item names it in `supersedes`, so a constraint survives unless a later claim
/// explicitly replaces it.
public struct ContextCarryReducer: Sendable {
    /// Creates a reducer.
    public init() {}

    /// Reduces child carries into one parent carry.
    ///
    /// - Parameter carries: The child carries, in chronological order.
    /// - Returns: The reduced carry. Superseded items stay in the list with the
    ///   `superseded` status, so history survives.
    public func reduce(_ carries: [ContextCarryState]) -> ContextCarryState {
        let flat = carries.flatMap(\.items)
        let supersededIDs = Set(flat.compactMap(\.supersedes))
        var result: [ContextCarryItem] = []
        var seenKeys: [String: Int] = [:]
        var seenPinIDs: Set<String> = []

        for item in flat {
            if item.category == .exactPins {
                guard seenPinIDs.insert(item.id).inserted else { continue }
                result.append(item)
                continue
            }
            if item.category == .goals || item.category == .constraints {
                let key = "\(item.category.rawValue)\u{1F}\(Self.normalize(item.text))"
                if let index = seenKeys[key] {
                    result[index] = Self.mergeCitations(result[index], item)
                    continue
                }
                seenKeys[key] = result.count
            }
            result.append(item)
        }

        return ContextCarryState(items: result.map { item in
            guard supersededIDs.contains(item.id), item.epistemicStatus != .superseded else { return item }
            return Self.markSuperseded(item)
        })
    }

    /// Normalizes text for deduplication. Case and whitespace do not matter.
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Merges the citations of two duplicate items, keeping the first identity.
    static func mergeCitations(_ lhs: ContextCarryItem, _ rhs: ContextCarryItem) -> ContextCarryItem {
        var citations = lhs.citations
        var seen = Set(citations.map(\.messageID))
        for citation in rhs.citations where seen.insert(citation.messageID).inserted {
            citations.append(citation)
        }
        return ContextCarryItem(
            id: lhs.id,
            category: lhs.category,
            text: lhs.text,
            origin: lhs.origin,
            epistemicStatus: lhs.epistemicStatus,
            citations: citations,
            supersedes: lhs.supersedes,
            topicLabels: lhs.topicLabels
        )
    }

    /// Returns a copy of the item with the `superseded` status.
    static func markSuperseded(_ item: ContextCarryItem) -> ContextCarryItem {
        ContextCarryItem(
            id: item.id,
            category: item.category,
            text: item.text,
            origin: item.origin,
            epistemicStatus: .superseded,
            citations: item.citations,
            supersedes: item.supersedes,
            topicLabels: item.topicLabels
        )
    }
}
