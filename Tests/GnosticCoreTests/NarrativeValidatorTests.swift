// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Narrative proposal validation and admission")
struct NarrativeValidatorTests {
    private let agentID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000001")!
    private let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000002")!
    private let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!

    private func makeProposal() -> NarrativeProposal {
        NarrativeProposal(
            id: NarrativeEntryID(rawValue: UUID()),
            kind: .lesson,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: NarrativeSourceReference(
                conversation: NarrativeConversationRange(firstMessageID: "msg-1", lastMessageID: "msg-3"),
                toolIDs: ["tool-search"],
                agentID: agentID,
                timelineID: timelineID,
                workspaceIDs: [workspaceID]
            ),
            observation: "Flexible tool schemas were observed.",
            interpretation: "Explicit parameter schemas improve validation.",
            lesson: ProposedLesson(summary: "Prefer explicit schemas."),
            importance: 0.5,
            confidence: 0.8,
            supportingEpisodes: [],
            isFactStatedSpeculation: false,
            isOverbroadSelfCharacterization: false
        )
    }

    private func makeState(existing: [NarrativeEntry] = []) -> NarrativeAuthoritativeState {
        NarrativeAuthoritativeState(
            agentID: agentID,
            timelineIDs: [timelineID],
            workspaceIDs: [workspaceID],
            filePaths: ["/src/main.swift"],
            unsafeMetadataValues: ["/private/token"]
        )
    }

    @Test("a well-formed proposal is admitted")
    func wellFormedProposalIsAdmitted() async throws {
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [] }
        )
        let entry = try await validator.validate(makeProposal(), against: makeState())
        #expect(entry.kind == .lesson)
        #expect(entry.lesson?.summary == "Prefer explicit schemas.")
        #expect(entry.observation == "Flexible tool schemas were observed.")
    }

    @Test("duplicate candidate id is rejected")
    func duplicateCandidateIdIsRejected() async {
        let existingNarrative = makeProposal()
        let storeEntry = NarrativeEntry(
            id: existingNarrative.id,
            kind: .lesson,
            occurredAt: existingNarrative.occurredAt,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: existingNarrative.source,
            observation: existingNarrative.observation,
            interpretation: existingNarrative.interpretation,
            lesson: existingNarrative.lesson,
            importance: existingNarrative.importance,
            confidence: existingNarrative.confidence,
            supersededIDs: []
        )
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [storeEntry] }
        )

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(existingNarrative, against: makeState())
        }
    }

    @Test("semantically duplicate proposal is rejected")
    func semanticallyDuplicateProposalIsRejected() async {
        let proposal = makeProposal()
        let firstId = NarrativeEntryID(rawValue: UUID())
        let prior = NarrativeEntry(
            id: firstId,
            kind: proposal.kind,
            occurredAt: proposal.occurredAt,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_050),
            source: proposal.source,
            observation: proposal.observation.lowercased(),
            interpretation: proposal.interpretation,
            lesson: proposal.lesson,
            importance: proposal.importance,
            confidence: proposal.confidence,
            supersededIDs: []
        )
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [prior] }
        )

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(proposal, against: makeState())
        }
    }

    @Test("proposal lacking required provenance is rejected")
    func proposalLackingProvenanceIsRejected() async throws {
        var proposal = makeProposal()
        proposal.source = NarrativeSourceReference(conversation: .empty)
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [] }
        )

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(proposal, against: makeState())
        }
    }

    @Test("fact-stated speculation is rejected")
    func factStatedSpeculationIsRejected() async throws {
        var proposal = makeProposal()
        proposal.isFactStatedSpeculation = true
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [] }
        )

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(proposal, against: makeState())
        }
    }

    @Test("over-broad self-characterization is rejected")
    func overbroadSelfCharacterizationIsRejected() async throws {
        var proposal = makeProposal()
        proposal.isOverbroadSelfCharacterization = true
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [] }
        )

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(proposal, against: makeState())
        }
    }

    @Test("sensitive literal is rejected")
    func sensitiveLiteralIsRejected() async throws {
        let validator = NarrativeValidator(
            sensitiveValueMatch: { $0.contains("PRIVATE_SECRET") },
            existingEntries: { [] }
        )
        var proposal = makeProposal()
        proposal.observation = "Exposed PRIVATE_SECRET in log output."

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(proposal, against: makeState())
        }
    }

    @Test("value sourced from unsafe metadata is rejected")
    func unsafeMetadataValueIsRejected() async throws {
        let validator = NarrativeValidator(
            sensitiveValueMatch: { $0.contains("/private/token") },
            existingEntries: { [] }
        )
        var proposal = makeProposal()
        proposal.interpretation = "Token path /private/token was involved."

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(proposal, against: makeState())
        }
    }

    @Test("operational self-model update requires multi-episode evidence")
    func operationalSelfModelRequiresMultiEpisodeEvidence() async throws {
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [] }
        )
        var proposal = makeProposal()
        proposal.kind = .operationalSelfModel
        proposal.supportingEpisodes = []
        proposal.lesson = nil

        await #expect(throws: NarrativeRejection.self) {
            try await validator.validate(proposal, against: makeState())
        }

        proposal.supportingEpisodes = [NarrativeEntryID(rawValue: UUID()), NarrativeEntryID(rawValue: UUID())]
        let admitted = try await validator.validate(proposal, against: makeState())
        #expect(admitted.kind == .operationalSelfModel)
    }

    @Test("confidence is lowered when provenance poorly supports interpretation")
    func confidenceIsLoweredWhenProvenanceIsWeak() async throws {
        let validator = NarrativeValidator(
            sensitiveValueMatch: { _ in false },
            existingEntries: { [] }
        )
        var proposal = makeProposal()
        proposal.interpretation = "References an identifier not in authoritative state: \((UUID().uuidString))"
        proposal.confidence = 0.95

        let admitted = try await validator.validate(proposal, against: makeState())
        #expect(admitted.confidence < 0.95)
    }

    @Test("rejection carries machine-readable reasons")
    func rejectionCarriesMachineReadableReasons() async {
        let validator = NarrativeValidator(
            sensitiveValueMatch: { $0.contains("PRIVATE_SECRET") },
            existingEntries: { [] }
        )
        var proposal = makeProposal()
        proposal.observation = "PRIVATE_SECRET leaked."
        proposal.supportingEpisodes = []

        do {
            _ = try await validator.validate(proposal, against: makeState())
            Issue.record("expected rejection")
        } catch let rejection as NarrativeRejection {
            #expect(!rejection.reasons.isEmpty)
            #expect(rejection.reasons.allSatisfy { !$0.code.isEmpty && !$0.reason.isEmpty })
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}