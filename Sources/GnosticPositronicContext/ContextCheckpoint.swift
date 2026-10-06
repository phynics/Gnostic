// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One bounded, structured checkpoint over a frozen history cut.
///
/// Under the SIMPLIFY gate decision (#431) the cover is flat: the checkpoint
/// covers `M1…Mk` with an ordered set of accepted leaf nodes, never a
/// mixed-resolution tree. The carry is the deterministic
/// ``ContextCarryReducer`` output over the covered leaves, so the structured
/// state stays authoritative and prose stays a projection of it.
///
/// The identity is content-addressed over the Timeline, the cut, the
/// host-computed source digest, the covered node IDs, and the schema and
/// policy versions — never the model identifier. The carry, the synopsis, the
/// curator version, and the revision are body and provenance, not identity.
public struct ContextCheckpoint: Codable, Sendable, Equatable {
    /// The content-addressed checkpoint identifier.
    public let id: String
    /// The Ascendant that owns the checkpoint.
    public let ascendantID: String
    /// The Timeline the checkpoint covers.
    public let timelineID: String
    /// The last raw message the checkpoint covers (`Mk`).
    public let throughMessageID: String
    /// The exact source range `M1…Mk`, with a host-computed digest.
    public let sourceRange: ContextSourceRange
    /// The accepted leaf node IDs whose coverage tiles `M1…Mk`, in order.
    public let coveredNodeIDs: [String]
    /// An optional synopsis. Absent means no prose.
    public let synopsis: String?
    /// The reduced carry over the covered leaves.
    public let carry: ContextCarryState
    /// The version label of the host component that built the checkpoint.
    public let curatorVersion: String
    /// The projection revision the checkpoint was minted against.
    ///
    /// The revision is activation bookkeeping, not content: minting the same
    /// cover again at another revision shares identity and body.
    public let revision: Int

    /// Creates one checkpoint and computes its content-addressed identity.
    ///
    /// - Parameters:
    ///   - ascendantID: The Ascendant that owns the checkpoint.
    ///   - timelineID: The Timeline the checkpoint covers.
    ///   - throughMessageID: The last covered raw message (`Mk`).
    ///   - sourceRange: The exact covered range with a host-computed digest.
    ///   - coveredNodeIDs: The accepted leaf node IDs tiling the range, in order.
    ///   - synopsis: The optional synopsis.
    ///   - carry: The reduced carry over the covered leaves.
    ///   - curatorVersion: The host component's version label.
    ///   - revision: The projection revision the checkpoint was minted against.
    ///   - schemaVersion: The schema version.
    ///   - policyVersion: The policy version.
    public init(
        ascendantID: String,
        timelineID: String,
        throughMessageID: String,
        sourceRange: ContextSourceRange,
        coveredNodeIDs: [String],
        synopsis: String? = nil,
        carry: ContextCarryState = ContextCarryState(),
        curatorVersion: String,
        revision: Int,
        schemaVersion: String = ContextSchemaVersion.current,
        policyVersion: String = ContextPolicyVersion.current
    ) {
        self.id = ContextCheckpointIdentity.make(
            timelineID: timelineID,
            throughMessageID: throughMessageID,
            sourceDigest: sourceRange.digest,
            coveredNodeIDs: coveredNodeIDs,
            schemaVersion: schemaVersion,
            policyVersion: policyVersion
        )
        self.ascendantID = ascendantID
        self.timelineID = timelineID
        self.throughMessageID = throughMessageID
        self.sourceRange = sourceRange
        self.coveredNodeIDs = coveredNodeIDs
        self.synopsis = synopsis
        self.carry = carry
        self.curatorVersion = curatorVersion
        self.revision = revision
    }

    /// The exact pins the checkpoint protects, projected from the carry.
    public var exactPins: [ContextCarryItem] {
        carry.items(in: .exactPins)
    }

    /// Whether two checkpoints carry the same content.
    ///
    /// The revision is activation bookkeeping, not content, so it does not
    /// participate in body equality. Everything else does.
    ///
    /// - Parameter other: The checkpoint to compare.
    /// - Returns: Whether the bodies match.
    public static func == (lhs: ContextCheckpoint, rhs: ContextCheckpoint) -> Bool {
        lhs.id == rhs.id
            && lhs.ascendantID == rhs.ascendantID
            && lhs.timelineID == rhs.timelineID
            && lhs.throughMessageID == rhs.throughMessageID
            && lhs.sourceRange == rhs.sourceRange
            && lhs.coveredNodeIDs == rhs.coveredNodeIDs
            && lhs.synopsis == rhs.synopsis
            && lhs.carry == rhs.carry
            && lhs.curatorVersion == rhs.curatorVersion
    }
}

/// Computes the content-addressed identity of a checkpoint.
public enum ContextCheckpointIdentity {
    /// Returns the checkpoint ID for the given identity inputs.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the checkpoint covers.
    ///   - throughMessageID: The last covered raw message.
    ///   - sourceDigest: The host-computed digest over `M1…Mk`.
    ///   - coveredNodeIDs: The covered leaf node IDs, in order.
    ///   - schemaVersion: The schema version.
    ///   - policyVersion: The policy version.
    /// - Returns: The content-addressed checkpoint ID.
    public static func make(
        timelineID: String,
        throughMessageID: String,
        sourceDigest: String,
        coveredNodeIDs: [String],
        schemaVersion: String,
        policyVersion: String
    ) -> String {
        ContextHashing.digest(
            [schemaVersion, policyVersion, timelineID, throughMessageID, sourceDigest] + coveredNodeIDs
        )
    }
}

/// Builds one flat checkpoint over a frozen history cut.
///
/// The planner is pure and deterministic. It selects the accepted leaves whose
/// coverage tiles `M1…Mk` exactly, rejects a cut that splits a tool
/// transaction, and reduces the covered leaves' carry. Replanning the same
/// leaves and cut gives the same checkpoint.
public struct ContextCheckpointPlanner: Sendable {
    /// The stable host version label for checkpoints this planner builds.
    public static let version = "checkpoint-v1"

    /// The host-owned bounds.
    public let descriptor: ContextDescriptor
    /// The carry reducer.
    public let reducer: ContextCarryReducer

    /// Creates a planner.
    ///
    /// - Parameters:
    ///   - descriptor: The host-owned bounds.
    ///   - reducer: The carry reducer.
    public init(
        descriptor: ContextDescriptor = .default,
        reducer: ContextCarryReducer = ContextCarryReducer()
    ) {
        self.descriptor = descriptor
        self.reducer = reducer
    }

    /// Plans one checkpoint over the cut at `throughMessageID`.
    ///
    /// - Parameters:
    ///   - ascendantID: The Ascendant that will own the checkpoint.
    ///   - timelineID: The Timeline the history belongs to.
    ///   - messages: The ordered raw history `M1…Mn`. The cut selects the
    ///     prefix `M1…Mk`; the tail `Mk+1…Mn` is only read for the boundary
    ///     check.
    ///   - leaves: The accepted leaf nodes. Order does not matter; the planner
    ///     orders them chronologically itself.
    ///   - throughMessageID: The last raw message the checkpoint covers.
    ///   - revision: The projection revision the checkpoint is minted against.
    /// - Returns: The planned checkpoint with a host-computed source range and
    ///   the reduced carry.
    /// - Throws: A `ContextError` when the cut is unknown, splits a tool
    ///   transaction, or the leaves do not tile the prefix exactly.
    public func plan(
        ascendantID: String,
        timelineID: String,
        messages: [ContextMessage],
        leaves: [ContextNode],
        throughMessageID: String,
        revision: Int
    ) throws -> ContextCheckpoint {
        for leaf in leaves where leaf.timelineID != timelineID || leaf.coverage.timelineID != timelineID {
            throw ContextError.crossTimeline
        }
        guard let cut = messages.firstIndex(where: { $0.id == throughMessageID }) else {
            throw ContextError.unknownSourceRange
        }
        // The offline analog of PositronicKit's tool-history validation: the
        // cut must not fall between an assistant tool call and its tool
        // result. The live seam (GNO-CTX-010) uses PositronicKit's own
        // boundary; this rule stands in for it offline.
        if cut + 1 < messages.count, messages[cut].role == .assistant, messages[cut + 1].role == .tool {
            throw ContextError.toolTransactionSplit
        }

        let prefixIDs = messages[...cut].map(\.id)
        let prefix = Set(prefixIDs)
        var covered: [ContextNode] = []
        var coveredIDs: [String] = []
        for leaf in chronological(leaves) {
            let ids = leaf.coverage.messageIDs
            guard let first = ids.first, prefix.contains(first) else { continue }
            // A leaf that starts inside the prefix but reaches past the cut
            // cannot be included without covering uncovered raw history, so
            // the cut split a leaf's coverage.
            guard ids.allSatisfy({ prefix.contains($0) }) else { throw ContextError.coverageGap }
            covered.append(leaf)
            coveredIDs.append(contentsOf: ids)
        }
        // The cover is exact: every prefix message is covered exactly once,
        // with no gaps and no overlaps.
        guard coveredIDs == prefixIDs else { throw ContextError.coverageGap }

        return ContextCheckpoint(
            ascendantID: ascendantID,
            timelineID: timelineID,
            throughMessageID: throughMessageID,
            sourceRange: ContextSourceRange.hostComputed(timelineID: timelineID, messageIDs: prefixIDs),
            coveredNodeIDs: covered.map(\.id),
            synopsis: nil,
            carry: reducer.reduce(covered.map(\.carry)),
            curatorVersion: Self.version,
            revision: revision
        )
    }

    /// Orders leaves chronologically by first covered message.
    private func chronological(_ leaves: [ContextNode]) -> [ContextNode] {
        leaves.sorted { ($0.coverage.firstMessageID ?? "") < ($1.coverage.firstMessageID ?? "") }
    }
}

/// Renders one checkpoint as deterministic prose.
///
/// The default projection is the active carry item texts joined by newline.
/// It carries no headers and no model prose, so it is byte-identical to the
/// gate's `incremental-flat` arm over the same leaves: the committed gate
/// evidence in `Documentation/Experiments/context-gate.json` stays
/// reproducible from this code.
public struct ContextCheckpointRenderer: Sendable {
    /// Creates a renderer.
    public init() {}

    /// Renders the checkpoint's active carry as plain text, in order.
    ///
    /// - Parameter checkpoint: The checkpoint to render.
    /// - Returns: The deterministic prose projection.
    public func render(_ checkpoint: ContextCheckpoint) -> String {
        checkpoint.carry.activeItems.map(\.text).joined(separator: "\n")
    }
}

/// Host validation for checkpoint candidates.
///
/// The validator checks coverage, digest, carry survival against the
/// deterministic reducer, host exact pins, and every descriptor bound. Host
/// validation, not model confidence, decides what becomes an accepted
/// checkpoint.
public struct ContextCheckpointValidator: Sendable {
    /// The host-owned bounds.
    public let descriptor: ContextDescriptor
    /// The carry reducer the candidate is checked against.
    public let reducer: ContextCarryReducer
    /// The exact pins host policy protects.
    public let hostPins: [ContextCarryItem]

    /// Creates a validator.
    ///
    /// - Parameters:
    ///   - descriptor: The host-owned bounds.
    ///   - reducer: The carry reducer.
    ///   - hostPins: The host exact pins.
    public init(
        descriptor: ContextDescriptor = .default,
        reducer: ContextCarryReducer = ContextCarryReducer(),
        hostPins: [ContextCarryItem] = []
    ) {
        self.descriptor = descriptor
        self.reducer = reducer
        self.hostPins = hostPins
    }

    /// Validates one checkpoint candidate against the leaves it claims.
    ///
    /// - Parameters:
    ///   - candidate: The checkpoint to validate.
    ///   - leaves: The accepted leaf nodes.
    /// - Returns: The validated checkpoint, unchanged.
    /// - Throws: A `ContextError` when any structural rule fails.
    public func validate(_ candidate: ContextCheckpoint, leaves: [ContextNode]) throws -> ContextCheckpoint {
        guard candidate.timelineID == candidate.sourceRange.timelineID else {
            throw ContextError.crossTimeline
        }
        for leaf in leaves where leaf.timelineID != candidate.timelineID || leaf.coverage.timelineID != candidate.timelineID {
            throw ContextError.crossTimeline
        }

        // The cut names the last covered message, and the coverage is not empty.
        guard !candidate.sourceRange.messageIDs.isEmpty,
              candidate.throughMessageID == candidate.sourceRange.lastMessageID
        else {
            throw ContextError.unknownSourceRange
        }

        // Every covered node resolves and the cover is chronological.
        let ordered = leaves.sorted { ($0.coverage.firstMessageID ?? "") < ($1.coverage.firstMessageID ?? "") }
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var covered: [ContextNode] = []
        for id in candidate.coveredNodeIDs {
            guard let node = byID[id] else { throw ContextError.unknownSourceRange }
            covered.append(node)
        }
        let expectedOrder = ordered.map(\.id).filter { candidate.coveredNodeIDs.contains($0) }
        guard expectedOrder == candidate.coveredNodeIDs else { throw ContextError.coverageGap }

        // The cover tiles the claimed range exactly, with no gaps and no overlaps.
        let coveredIDs = covered.flatMap { $0.coverage.messageIDs }
        guard coveredIDs == candidate.sourceRange.messageIDs else { throw ContextError.coverageGap }

        // The recorded digest is the host digest of the claimed range.
        let recomputed = ContextSourceRange.hostComputed(
            timelineID: candidate.timelineID,
            messageIDs: candidate.sourceRange.messageIDs
        )
        guard recomputed.digest == candidate.sourceRange.digest else { throw ContextError.unknownSourceRange }

        // The carry survives the deterministic reduction of the covered leaves.
        guard candidate.carry == reducer.reduce(covered.map(\.carry)) else {
            throw ContextError.carrySurvivalFailed
        }

        // Host exact pins cannot disappear.
        let present = Set(candidate.carry.items.map { ContextCarryReducer.normalize($0.text) })
        for pin in hostPins where !present.contains(ContextCarryReducer.normalize(pin.text)) {
            throw ContextError.carrySurvivalFailed
        }

        try validateBounds(candidate)
        return candidate
    }

    private func validateBounds(_ candidate: ContextCheckpoint) throws {
        if let synopsis = candidate.synopsis, synopsis.utf8.count > descriptor.maxSynopsisBytes {
            throw ContextError.budgetExceeded
        }
        for item in candidate.carry.items {
            if item.text.utf8.count > descriptor.maxItemBytes { throw ContextError.budgetExceeded }
            if item.citations.count > descriptor.maxReferencesPerItem { throw ContextError.budgetExceeded }
        }
        for category in ContextCarryCategory.allCases {
            if candidate.carry.items(in: category).count > descriptor.maxItemsPerCategory {
                throw ContextError.budgetExceeded
            }
        }
        let totalBytes = (candidate.synopsis?.utf8.count ?? 0)
            + candidate.carry.items.reduce(0) { $0 + $1.text.utf8.count }
        if totalBytes > descriptor.maxTotalAcceptedBytes { throw ContextError.budgetExceeded }
    }
}
