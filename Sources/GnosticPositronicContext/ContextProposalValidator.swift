// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Host validation for curator proposals.
///
/// Host validation, not model confidence, decides what becomes an accepted leaf
/// node. The validator checks provenance, the origin ceiling, corrections and
/// supersession, host exact pins, and every descriptor bound. It returns a
/// content-addressed leaf node; it never trusts a curator-supplied identity.
public struct ContextProposalValidator: Sendable {
    /// The host-owned bounds.
    public let descriptor: ContextDescriptor
    /// The exact pins host policy protects.
    ///
    /// Host pins win by ID. A curator cannot remove them, because the validator
    /// always merges them into the accepted carry.
    public let hostPins: [ContextCarryItem]

    /// Creates a validator.
    ///
    /// - Parameters:
    ///   - descriptor: The host-owned bounds.
    ///   - hostPins: The host exact pins.
    public init(descriptor: ContextDescriptor = .default, hostPins: [ContextCarryItem] = []) {
        self.descriptor = descriptor
        self.hostPins = hostPins
    }

    /// Validates one proposal and returns the accepted leaf node.
    ///
    /// - Parameters:
    ///   - leaf: The proposal and the episode it covers.
    ///   - expectedTimelineID: The Timeline the store partition expects.
    ///   - activeCarry: The carry already accepted for the Timeline.
    /// - Returns: The accepted, content-addressed leaf node.
    /// - Throws: A `ContextError` when any structural rule fails.
    public func validate(
        _ leaf: ContextLeafProposal,
        expectedTimelineID: String,
        activeCarry: ContextCarryState
    ) throws -> ContextNode {
        let proposal = leaf.proposal
        let episode = leaf.episode

        guard episode.timelineID == expectedTimelineID else { throw ContextError.crossTimeline }
        guard proposal.schemaVersion == descriptor.schemaVersion,
              proposal.policyVersion == descriptor.policyVersion
        else {
            throw ContextError.descriptorMismatch
        }
        guard Set(proposal.items.map(\.id)).count == proposal.items.count else {
            throw ContextError.malformedProposal
        }
        for item in proposal.items where item.origin == .systemConstraint {
            // Only host policy may claim system authority.
            throw ContextError.invalidCitation
        }

        let hostPinIDs = Set(hostPins.map(\.id))
        var merged = proposal.items.filter { !hostPinIDs.contains($0.id) }
        merged.append(contentsOf: hostPins)

        try validateBounds(synopsis: proposal.synopsis, items: merged)

        for item in merged {
            var roles = Set<ContextTurnRole>()
            for citation in item.citations {
                guard let message = episode.message(id: citation.messageID) else {
                    throw ContextError.unknownSourceRange
                }
                roles.insert(message.role)
            }
            if item.origin != .systemConstraint, roles.isDisjoint(with: allowedRoles(for: item.origin)) {
                throw ContextError.invalidCitation
            }
            if item.epistemicStatus == .verified, !roles.contains(.tool) {
                throw ContextError.invalidCitation
            }
        }

        try validateSupersession(items: merged, activeCarry: activeCarry)

        return ContextNode(
            timelineID: episode.timelineID,
            coverage: leaf.coverage,
            children: [],
            synopsis: proposal.synopsis,
            carry: ContextCarryState(items: merged),
            curatorVersion: leaf.curatorVersion
        )
    }

    private func validateBounds(synopsis: String?, items: [ContextCarryItem]) throws {
        if let synopsis, synopsis.utf8.count > descriptor.maxSynopsisBytes {
            throw ContextError.budgetExceeded
        }
        for item in items {
            if item.text.utf8.count > descriptor.maxItemBytes { throw ContextError.budgetExceeded }
            if item.citations.count > descriptor.maxReferencesPerItem { throw ContextError.budgetExceeded }
        }
        for category in ContextCarryCategory.allCases {
            if items.filter({ $0.category == category }).count > descriptor.maxItemsPerCategory {
                throw ContextError.budgetExceeded
            }
        }
        let totalBytes = (synopsis?.utf8.count ?? 0) + items.reduce(0) { $0 + $1.text.utf8.count }
        if totalBytes > descriptor.maxTotalAcceptedBytes { throw ContextError.budgetExceeded }
    }

    private func validateSupersession(items: [ContextCarryItem], activeCarry: ContextCarryState) throws {
        let proposalByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let activeByID = Dictionary(activeCarry.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            if item.category == .corrections, item.supersedes == nil {
                throw ContextError.invalidCitation
            }
            guard let targetID = item.supersedes else { continue }
            guard let target = proposalByID[targetID] ?? activeByID[targetID] else {
                throw ContextError.invalidCitation
            }
            guard let newest = item.citations.map(\.messageID).max(),
                  let targetNewest = target.citations.map(\.messageID).max(),
                  newest > targetNewest
            else {
                throw ContextError.invalidCitation
            }
        }
    }

    private func allowedRoles(for origin: ContextClaimOrigin) -> Set<ContextTurnRole> {
        switch origin {
        case .userInstruction, .userStatement, .acceptedDecision:
            [.user]
        case .assistantAssertion:
            [.assistant]
        case .toolEvidence:
            [.tool]
        case .systemConstraint:
            []
        }
    }
}
