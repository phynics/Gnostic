// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Validates and admits model-generated narrative proposals before they reach
/// the append-only store.
///
/// The validator is intentionally injectable: sensitive-value matching and
/// authoritative-state lookup are supplied so tests require no credentials or
/// LLM. Validation never copies authoritative orchestration state into the
/// admitted narrative; it references only the source identifiers.
public struct NarrativeValidator: Sendable {
    /// The minimum number of supporting episodes an operational self-model
    /// update requires before it may be admitted.
    public var operationalSelfModelEvidenceFloor: Int
    /// The fraction deducted from confidence when provenance weakly supports
    /// the proposed interpretation.
    public var weakProvenancePenalty: Double
    /// A normalized-signature match used to detect semantic duplicates.
    private let sensitiveValueMatch: @Sendable (String) -> Bool
    /// Supplies the currently admitted entries for duplicate detection.
    private let existingEntries: @Sendable () -> [NarrativeEntry]

    /// Creates a validator with injected dependencies.
    ///
    /// - Parameters:
    ///   - sensitiveValueMatch: Returns true when a narrative value is
    ///     sensitive (a configured literal or unsafe metadata value) and must
    ///     be rejected.
    ///   - existingEntries: Returns the currently admitted narrative entries.
    ///   - operationalSelfModelEvidenceFloor: Evidence floor for
    ///     `.operationalSelfModel` proposals. Defaults to 2.
    ///   - weakProvenancePenalty: Confidence penalty for weakly supported
    ///     interpretations. Defaults to 0.3.
    public init(
        sensitiveValueMatch: @escaping @Sendable (String) -> Bool,
        existingEntries: @escaping @Sendable () -> [NarrativeEntry],
        operationalSelfModelEvidenceFloor: Int = 2,
        weakProvenancePenalty: Double = 0.3
    ) {
        self.sensitiveValueMatch = sensitiveValueMatch
        self.existingEntries = existingEntries
        self.operationalSelfModelEvidenceFloor = operationalSelfModelEvidenceFloor
        self.weakProvenancePenalty = weakProvenancePenalty
    }

    /// Validates a proposal against authoritative state and admits it or
    /// throws an ErrorKit-compatible `NarrativeRejection`.
    ///
    /// - Parameters:
    ///   - proposal: The candidate proposal.
    ///   - state: The authoritative current orchestration state.
    /// - Returns: The admitted immutable `NarrativeEntry`.
    /// - Throws: `NarrativeRejection` when the proposal cannot be admitted.
    public func validate(_ proposal: NarrativeProposal, against state: NarrativeAuthoritativeState) async throws -> NarrativeEntry {
        var reasons: [NarrativeRejectionReason] = []
        let admitted = existingEntries()

        if admitted.contains(where: { $0.id == proposal.id }) {
            reasons.append(NarrativeRejectionReason(
                code: "duplicateID",
                reason: "Identifier \(proposal.id.rawValue.uuidString) already exists."
            ))
        }
        if let semanticDuplicate = admitted.first(where: {
            $0.kind == proposal.kind
                && normalized($0.observation) == normalized(proposal.observation)
                && normalized($0.interpretation) == normalized(proposal.interpretation)
        }) {
            reasons.append(NarrativeRejectionReason(
                code: "semanticDuplicate",
                reason: "Semantically duplicates entry \(semanticDuplicate.id.rawValue.uuidString)."
            ))
        }
        if proposal.source.conversation == .empty
            && proposal.source.toolIDs.isEmpty
            && proposal.source.correlationIDs.isEmpty
            && proposal.source.workspaceIDs.isEmpty
            && proposal.source.filePaths.isEmpty {
            reasons.append(NarrativeRejectionReason(
                code: "missingProvenance",
                reason: "Proposal lacks required provenance references."
            ))
        }
        if proposal.isFactStatedSpeculation {
            reasons.append(NarrativeRejectionReason(
                code: "factStatedSpeculation",
                reason: "Observation states speculation as fact."
            ))
        }
        if proposal.isOverbroadSelfCharacterization {
            reasons.append(NarrativeRejectionReason(
                code: "overbroadSelfCharacterization",
                reason: "Proposal makes an over-broad self-characterization."
            ))
        }

        let narrativeText = [
            proposal.observation,
            proposal.interpretation,
            proposal.lesson?.summary ?? "",
            proposal.openThread?.summary ?? "",
        ].joined(separator: "\n")
        if sensitiveValueMatch(narrativeText) {
            reasons.append(NarrativeRejectionReason(
                code: "sensitiveValue",
                reason: "Proposal contains a sensitive value."
            ))
        }

        if proposal.kind == .operationalSelfModel {
            let evidenceCount = Set(proposal.supportingEpisodes).count
            if evidenceCount < operationalSelfModelEvidenceFloor {
                reasons.append(NarrativeRejectionReason(
                    code: "insufficientEvidence",
                    reason: "Operational self-model update needs \(operationalSelfModelEvidenceFloor) supporting episodes; had \(evidenceCount)."
                ))
            }
        }

        if !reasons.isEmpty {
            throw NarrativeRejection(reasons: reasons)
        }

        return NarrativeEntry(
            id: NarrativeEntryID(rawValue: proposal.id.rawValue),
            kind: proposal.kind,
            occurredAt: proposal.occurredAt,
            recordedAt: Date(),
            source: proposal.source,
            observation: proposal.observation,
            interpretation: proposal.interpretation,
            lesson: proposal.lesson,
            openThread: proposal.openThread,
            importance: proposal.importance,
            confidence: confidence(proposal: proposal, against: state),
            supersededIDs: []
        )
    }

    private func confidence(proposal: NarrativeProposal, against state: NarrativeAuthoritativeState) -> Double {
        let authoritative: Set<String> =
            Set(state.workspaceIDs.map(\.uuidString))
            .union(state.timelineIDs.map(\.uuidString))
            .union(state.filePaths)

        let sourceReferences =
            proposal.source.workspaceIDs.map(\.uuidString) + proposal.source.toolIDs
        let referencedInInterpretation = identifiers(in: proposal.interpretation)
        let referenced = sourceReferences + referencedInInterpretation

        // Provenance cannot support the interpretation when it references
        // identifiers absent from authoritative state.
        if !referenced.isEmpty, !referenced.allSatisfy({ authoritative.contains($0) }) {
            return max(0.0, proposal.confidence - weakProvenancePenalty)
        }
        return proposal.confidence
    }

    private func identifiers(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .map(String.init)
            .filter { token in
                (token.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, options: .regularExpression) != nil)
                    || token.contains("/")
            }
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}