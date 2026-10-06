// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

extension ContextCarryState {
    /// The carry items rendered as plain text, in order.
    ///
    /// A checkpoint projection renders accepted carry this way. The rendering is
    /// deterministic and carries no model prose.
    public var rendered: String {
        items.map(\.text).joined(separator: "\n")
    }
}

/// One immutable episode the curator sees.
///
/// The episode is a chronological slice of a Timeline. It exposes no store
/// authority: a curator can read the messages and cite them, nothing more.
public struct ContextEpisode: Codable, Sendable, Equatable {
    /// The Timeline the episode belongs to.
    public let timelineID: String
    /// The episode messages, in chronological order.
    public let messages: [ContextMessage]

    /// Creates an episode.
    public init(timelineID: String, messages: [ContextMessage]) {
        self.timelineID = timelineID
        self.messages = messages
    }

    /// The message IDs, in order.
    public var messageIDs: [String] {
        messages.map(\.id)
    }

    /// The host-computed source range the episode covers.
    public var sourceRange: ContextSourceRange {
        ContextSourceRange.hostComputed(timelineID: timelineID, messageIDs: messageIDs)
    }

    /// Returns one message by ID.
    ///
    /// - Parameter id: The message ID.
    /// - Returns: The message, or `nil`.
    public func message(id: String) -> ContextMessage? {
        messages.first { $0.id == id }
    }
}

/// A structured semantic proposal for one episode.
///
/// Every item cites source message IDs from the episode. The schema and policy
/// versions come from the descriptor the host issued, never from the model.
public struct ContextProposal: Codable, Sendable, Equatable {
    /// The schema version the proposal was made against.
    public let schemaVersion: String
    /// The policy version the proposal was made against.
    public let policyVersion: String
    /// An optional synopsis.
    public let synopsis: String?
    /// The carry items, across every category.
    public let items: [ContextCarryItem]
    /// Topic labels. Metadata only; labels never decide coverage.
    public let topicLabels: [String]

    /// Creates a proposal.
    public init(
        schemaVersion: String,
        policyVersion: String,
        synopsis: String? = nil,
        items: [ContextCarryItem] = [],
        topicLabels: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
        self.synopsis = synopsis
        self.items = items
        self.topicLabels = topicLabels
    }

    /// The proposal's carry state.
    public var carry: ContextCarryState {
        ContextCarryState(items: items)
    }

    /// The proposal rendered as plain text.
    ///
    /// The benchmark scores this projection, so it measures what the curator
    /// chose to keep, not how the host later phrases it.
    public var rendered: String {
        ([synopsis] + items.map(\.text)).compactMap { $0 }.joined(separator: "\n")
    }
}

/// A proposal paired with the episode it covers.
///
/// The pair is the input to leaf commit (GNO-CTX-004). The coverage comes from
/// the episode, not from the proposal.
public struct ContextLeafProposal: Sendable, Equatable {
    /// The episode the proposal covers.
    public let episode: ContextEpisode
    /// The proposal.
    public let proposal: ContextProposal

    /// Creates a leaf proposal.
    public init(episode: ContextEpisode, proposal: ContextProposal) {
        self.episode = episode
        self.proposal = proposal
    }

    /// The host-computed coverage range.
    public var coverage: ContextSourceRange {
        episode.sourceRange
    }
}
