// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The schema version of a context node body.
///
/// The version participates in the content-addressed node ID, so a schema change
/// produces a different identity rather than silently reinterpreting old nodes.
public enum ContextSchemaVersion {
    /// The current schema version.
    public static let current = "ctx-schema-v1"
}

/// The host policy version that bounds what a curator may propose.
///
/// The version participates in the content-addressed node ID, so a policy change
/// produces a different identity rather than silently reinterpreting old nodes.
public enum ContextPolicyVersion {
    /// The current policy version.
    public static let current = "ctx-policy-v1"
}

/// One immutable episode message the curator may cite.
///
/// The context pipeline treats message text as historical data. It is never an
/// instruction, so the type carries the role that produced it.
public struct ContextMessage: Codable, Sendable, Equatable, Hashable {
    /// The stable message identifier within a Timeline.
    public let id: String
    /// The role that produced the message.
    public let role: ContextTurnRole
    /// The raw text.
    public let text: String

    /// Creates one message.
    public init(id: String, role: ContextTurnRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    /// Returns the stable message ID for a transcript turn index.
    ///
    /// - Parameter index: The zero-based turn index.
    /// - Returns: The message ID.
    public static func id(forTurnIndex index: Int) -> String {
        "m-\(ContextHashing.pathComponent(index))"
    }
}

/// A citation to one source message.
///
/// The citation carries only the message ID. The host resolves the role from the
/// episode, so a proposal cannot claim a role it did not cite.
public struct ContextCitation: Codable, Sendable, Equatable, Hashable {
    /// The cited message ID.
    public let messageID: String

    /// Creates a citation.
    public init(messageID: String) {
        self.messageID = messageID
    }
}

/// Where a carry item's claim came from.
///
/// The origin orders by authority. A curator may not claim an origin stronger
/// than the roles it cites (GNO-CTX-004).
public enum ContextClaimOrigin: String, Codable, Sendable, Equatable, CaseIterable {
    /// A direct user instruction.
    case userInstruction
    /// A user statement that is not an instruction.
    case userStatement
    /// An assistant assertion, the weakest origin.
    case assistantAssertion
    /// Evidence produced by a tool result.
    case toolEvidence
    /// A decision the user accepted.
    case acceptedDecision
    /// A host system constraint.
    case systemConstraint
}

/// How well a carry item's claim is supported.
public enum ContextEpistemicStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Claimed without further support.
    case asserted
    /// Inferred by the curator.
    case inferred
    /// Supported by tool evidence.
    case verified
    /// Contradicted by a later source.
    case disputed
    /// Replaced by a later claim.
    case superseded
}

/// The carry category an item belongs to.
public enum ContextCarryCategory: String, Codable, Sendable, Equatable, CaseIterable {
    /// A goal the conversation is pursuing.
    case goals
    /// A constraint that bounds the solution.
    case constraints
    /// A decision that was made.
    case decisions
    /// A question that is still open.
    case unresolvedQuestions
    /// A fact the conversation established.
    case facts
    /// An artifact the conversation produced.
    case artifacts
    /// A correction to an earlier claim.
    case corrections
    /// A next action.
    case nextActions
    /// An exact pin the host policy protects.
    case exactPins
}

/// One carry item with its provenance.
public struct ContextCarryItem: Codable, Sendable, Equatable, Hashable {
    /// The stable item identifier within a node.
    public let id: String
    /// The category the item belongs to.
    public let category: ContextCarryCategory
    /// The item text.
    public let text: String
    /// Where the claim came from.
    public let origin: ContextClaimOrigin
    /// How well the claim is supported.
    public let epistemicStatus: ContextEpistemicStatus
    /// The source messages the item cites.
    public let citations: [ContextCitation]
    /// The prior item this item corrects or supersedes, when any.
    public let supersedes: String?
    /// Topic labels. Metadata only; labels never decide coverage.
    public let topicLabels: [String]

    /// Creates a carry item.
    public init(
        id: String,
        category: ContextCarryCategory,
        text: String,
        origin: ContextClaimOrigin,
        epistemicStatus: ContextEpistemicStatus,
        citations: [ContextCitation],
        supersedes: String? = nil,
        topicLabels: [String] = []
    ) {
        self.id = id
        self.category = category
        self.text = text
        self.origin = origin
        self.epistemicStatus = epistemicStatus
        self.citations = citations
        self.supersedes = supersedes
        self.topicLabels = topicLabels
    }
}

/// The carry state a context node exposes.
///
/// The state is a flat list of items. Every item names its category, so the
/// reducer can group, deduplicate, and apply supersession without a second
/// schema.
public struct ContextCarryState: Codable, Sendable, Equatable {
    /// The carry items.
    public let items: [ContextCarryItem]

    /// Creates a carry state.
    ///
    /// - Parameter items: The carry items.
    public init(items: [ContextCarryItem] = []) {
        self.items = items
    }

    /// Returns the items in one category, in order.
    ///
    /// - Parameter category: The category to filter.
    /// - Returns: The matching items.
    public func items(in category: ContextCarryCategory) -> [ContextCarryItem] {
        items.filter { $0.category == category }
    }
}

/// The exact source range a context node covers.
///
/// The host computes `digest`. The model never supplies it. A node's identity
/// depends on the digest, so a curator cannot forge coverage.
public struct ContextSourceRange: Codable, Sendable, Equatable, Hashable {
    /// The Timeline the range belongs to.
    public let timelineID: String
    /// The covered message IDs, in chronological order.
    public let messageIDs: [String]
    /// The host-computed digest of the covered source.
    public let digest: String

    /// Creates a source range.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the range belongs to.
    ///   - messageIDs: The covered message IDs, in order.
    ///   - digest: The host-computed source digest.
    public init(timelineID: String, messageIDs: [String], digest: String) {
        self.timelineID = timelineID
        self.messageIDs = messageIDs
        self.digest = digest
    }

    /// The first covered message ID.
    public var firstMessageID: String? {
        messageIDs.first
    }

    /// The last covered message ID.
    public var lastMessageID: String? {
        messageIDs.last
    }

    /// Whether the range covers no messages.
    public var isEmpty: Bool {
        messageIDs.isEmpty
    }

    /// Builds a range and computes its digest from the message IDs.
    ///
    /// This is the host path. It digests the identity of the covered messages,
    /// not their text, because the store holds no conversation history.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the range belongs to.
    ///   - messageIDs: The covered message IDs, in order.
    /// - Returns: The range with a host-computed digest.
    public static func hostComputed(timelineID: String, messageIDs: [String]) -> ContextSourceRange {
        ContextSourceRange(
            timelineID: timelineID,
            messageIDs: messageIDs,
            digest: ContextHashing.digest([timelineID] + messageIDs)
        )
    }
}

/// A content-addressed context node.
///
/// The ID derives from the Timeline, the source digest, the child IDs, and the
/// schema and policy versions. It never derives from the model identifier, so
/// two curators that produce the same accepted body share an identity.
public struct ContextNode: Codable, Sendable, Equatable {
    /// The content-addressed node identifier.
    public let id: String
    /// The Timeline the node belongs to.
    public let timelineID: String
    /// The exact source range the node covers.
    public let coverage: ContextSourceRange
    /// The child node IDs, in chronological order.
    public let children: [String]
    /// An optional synopsis. Absent means no prose.
    public let synopsis: String?
    /// The carry state the node exposes.
    public let carry: ContextCarryState
    /// The curator version that produced the node.
    public let curatorVersion: String

    /// Creates a context node and computes its content-addressed ID.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the node belongs to.
    ///   - coverage: The exact source range.
    ///   - children: The child node IDs, in order.
    ///   - synopsis: The optional synopsis.
    ///   - carry: The carry state.
    ///   - curatorVersion: The curator version.
    ///   - schemaVersion: The schema version.
    ///   - policyVersion: The policy version.
    public init(
        timelineID: String,
        coverage: ContextSourceRange,
        children: [String] = [],
        synopsis: String? = nil,
        carry: ContextCarryState = ContextCarryState(),
        curatorVersion: String,
        schemaVersion: String = ContextSchemaVersion.current,
        policyVersion: String = ContextPolicyVersion.current
    ) {
        self.id = ContextNodeIdentity.make(
            timelineID: timelineID,
            sourceDigest: coverage.digest,
            childIDs: children,
            schemaVersion: schemaVersion,
            policyVersion: policyVersion
        )
        self.timelineID = timelineID
        self.coverage = coverage
        self.children = children
        self.synopsis = synopsis
        self.carry = carry
        self.curatorVersion = curatorVersion
    }

    /// Whether another node has the same semantic body.
    ///
    /// The curator version is provenance, not body. Two curators that produce
    /// the same accepted body share an identity, so the store treats them as
    /// the same node.
    ///
    /// - Parameter other: The node to compare.
    /// - Returns: Whether the bodies match.
    public func hasSameBody(as other: ContextNode) -> Bool {
        timelineID == other.timelineID
            && coverage == other.coverage
            && children == other.children
            && synopsis == other.synopsis
            && carry == other.carry
    }
}

/// Computes the content-addressed identity of a context node.
public enum ContextNodeIdentity {
    /// Returns the node ID for the given identity inputs.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the node belongs to.
    ///   - sourceDigest: The host-computed source digest.
    ///   - childIDs: The child node IDs, in order.
    ///   - schemaVersion: The schema version.
    ///   - policyVersion: The policy version.
    /// - Returns: The content-addressed node ID.
    public static func make(
        timelineID: String,
        sourceDigest: String,
        childIDs: [String],
        schemaVersion: String,
        policyVersion: String
    ) -> String {
        ContextHashing.digest([schemaVersion, policyVersion, timelineID, sourceDigest] + childIDs)
    }
}

/// The partition key for a context store.
///
/// The store partitions by Ascendant and Timeline, so two Ascendants or two
/// Timelines never share accepted nodes.
public struct ContextStoreKey: Codable, Sendable, Equatable, Hashable {
    /// The Ascendant that owns the partition.
    public let ascendantID: String
    /// The Timeline that owns the partition.
    public let timelineID: String

    /// Creates a partition key.
    public init(ascendantID: String, timelineID: String) {
        self.ascendantID = ascendantID
        self.timelineID = timelineID
    }
}
