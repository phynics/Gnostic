// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticKit
import Testing

@testable import GnosticPositronicContext

@Suite("Context proposal validation and leaf commit")
struct ContextValidationTests {
    private let key = ContextStoreKey(ascendantID: "asc-1", timelineID: "tl-1")
    private let assistantID = "m-000000003"
    private let userID = "m-000000002"
    private let toolID = "m-000000017"

    @Test("the fixture replay validates and commits one leaf per episode")
    func fixtureReplayCommitsLeaves() async throws {
        let store = InMemoryContextStore()
        let committer = ContextLeafCommitter(store: store, validator: ContextProposalValidator())
        let replay = ContextEpisodeReplay(timelineID: "tl-1", episodeSize: 8)
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let leaves = try await replay.replay(transcript: transcript, descriptor: .default, curator: FixtureContextCurator())
        var active = ContextCarryState()
        for leaf in leaves {
            let node = try await committer.commit(leaf, for: key, activeCarry: active)
            active = ContextCarryState(items: active.items + node.carry.items)
        }
        #expect(await store.acceptedNodes(for: key).count == leaves.count)
        #expect(await store.rootNodeIDs(for: key).count == leaves.count)

        let answer = active.rendered
        for fixture in ExperimentFixtureLibrary.plantedObligations {
            let score = ExperimentAssertionScorer().score(answer: answer, checks: fixture.checks)
            #expect(score.passed == score.total, "\(fixture.id) failed")
        }
    }

    @Test("a fabricated source ID is rejected")
    func rejectsFabricatedSourceID() async throws {
        let leaf = self.leaf(items: [item(citations: ["m-999999999"])])
        #expect(throws: ContextError.unknownSourceRange) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("a cross-Timeline episode is rejected")
    func rejectsCrossTimelineEpisode() async throws {
        let leaf = self.leaf(items: [item(citations: [assistantID])])
        #expect(throws: ContextError.crossTimeline) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-2", activeCarry: ContextCarryState())
        }
    }

    @Test("an assistant assertion promoted to verified without tool evidence is rejected")
    func rejectsPromotedVerified() async throws {
        let leaf = self.leaf(items: [item(origin: .assistantAssertion, status: .verified, citations: [assistantID])])
        #expect(throws: ContextError.invalidCitation) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("a user instruction that cites only an assistant message is rejected")
    func rejectsOriginExceedingRoles() async throws {
        let leaf = self.leaf(items: [item(origin: .userInstruction, citations: [assistantID])])
        #expect(throws: ContextError.invalidCitation) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("a fake correction with an unknown target is rejected")
    func rejectsFakeCorrection() async throws {
        let leaf = self.leaf(items: [
            item(id: "fix", category: .corrections, citations: [assistantID], supersedes: "missing")
        ])
        #expect(throws: ContextError.invalidCitation) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("a correction that does not cite a newer source is rejected")
    func rejectsStaleCorrection() async throws {
        let old = item(id: "old", citations: [assistantID])
        let stale = item(id: "stale", category: .corrections, citations: [userID], supersedes: "old")
        let leaf = self.leaf(items: [old, stale])
        #expect(throws: ContextError.invalidCitation) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("a correction without a supersedes target is rejected")
    func rejectsCorrectionWithoutTarget() async throws {
        let leaf = self.leaf(items: [item(category: .corrections, citations: [assistantID])])
        #expect(throws: ContextError.invalidCitation) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("an oversized synopsis is rejected")
    func rejectsOversizedSynopsis() async throws {
        let leaf = self.leaf(items: [item(citations: [assistantID])], synopsis: "this synopsis is far too long")
        #expect(throws: ContextError.budgetExceeded) {
            _ = try self.smallValidator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("an oversized item is rejected")
    func rejectsOversizedItem() async throws {
        let leaf = self.leaf(items: [item(text: "0123456789", citations: [assistantID])])
        #expect(throws: ContextError.budgetExceeded) {
            _ = try self.smallValidator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("too many citations are rejected")
    func rejectsTooManyCitations() async throws {
        let leaf = self.leaf(items: [item(citations: [assistantID, userID])])
        #expect(throws: ContextError.budgetExceeded) {
            _ = try self.smallValidator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("a mismatched descriptor version is rejected")
    func rejectsDescriptorMismatch() async throws {
        let leaf = self.leaf(items: [item(citations: [assistantID])], schemaVersion: "other")
        #expect(throws: ContextError.descriptorMismatch) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    @Test("a duplicate proposal commits idempotently")
    func duplicateCommitIsIdempotent() async throws {
        let store = InMemoryContextStore()
        let committer = ContextLeafCommitter(store: store, validator: ContextProposalValidator())
        let leaf = self.leaf(items: [item(citations: [assistantID])])
        let first = try await committer.commit(leaf, for: key, activeCarry: ContextCarryState())
        let second = try await committer.commit(leaf, for: key, activeCarry: ContextCarryState())
        #expect(first.id == second.id)
        #expect(await store.acceptedNodes(for: key).count == 1)
    }

    @Test("host exact pins cannot be removed by the curator")
    func hostPinsCannotBeRemoved() async throws {
        let pin = ContextCarryItem(
            id: "host-pin",
            category: .exactPins,
            text: "Host pin: port 8317.",
            origin: .systemConstraint,
            epistemicStatus: .asserted,
            citations: [ContextCitation(messageID: assistantID)]
        )
        let validator = ContextProposalValidator(hostPins: [pin])
        let leaf = self.leaf(items: [item(citations: [assistantID])])
        let node = try validator.validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        #expect(node.carry.items.contains { $0.id == "host-pin" })
    }

    @Test("a curator cannot claim host system authority")
    func maliciousToolTextCannotClaimSystemAuthority() async throws {
        let leaf = self.leaf(items: [
            item(origin: .systemConstraint, status: .asserted, citations: [toolID])
        ])
        #expect(throws: ContextError.invalidCitation) {
            _ = try self.validator().validate(leaf, expectedTimelineID: "tl-1", activeCarry: ContextCarryState())
        }
    }

    private func validator() -> ContextProposalValidator {
        ContextProposalValidator()
    }

    private func smallValidator() -> ContextProposalValidator {
        ContextProposalValidator(
            descriptor: ContextDescriptor(
                maxItemsPerCategory: 2,
                maxSynopsisBytes: 8,
                maxItemBytes: 8,
                maxReferencesPerItem: 1,
                maxTotalAcceptedBytes: 16,
                minimumFanOut: 4,
                maximumFanOut: 8
            )
        )
    }

    private func episode() -> ContextEpisode {
        ContextEpisode(
            timelineID: "tl-1",
            messages: [
                ContextMessage(id: userID, role: .user, text: "Which port?"),
                ContextMessage(id: assistantID, role: .assistant, text: "The broker listens on port 8317."),
                ContextMessage(id: toolID, role: .tool, text: "Tool result: port 8317 confirmed."),
            ]
        )
    }

    private func leaf(
        items: [ContextCarryItem],
        synopsis: String? = nil,
        schemaVersion: String = ContextSchemaVersion.current
    ) -> ContextLeafProposal {
        ContextLeafProposal(
            episode: episode(),
            proposal: ContextProposal(
                schemaVersion: schemaVersion,
                policyVersion: ContextPolicyVersion.current,
                synopsis: synopsis,
                items: items
            ),
            curatorVersion: "fixture-v1"
        )
    }

    private func item(
        id: String = "fact",
        category: ContextCarryCategory = .facts,
        text: String = "fact",
        origin: ContextClaimOrigin = .assistantAssertion,
        status: ContextEpistemicStatus = .asserted,
        citations: [String],
        supersedes: String? = nil
    ) -> ContextCarryItem {
        ContextCarryItem(
            id: id,
            category: category,
            text: text,
            origin: origin,
            epistemicStatus: status,
            citations: citations.map(ContextCitation.init(messageID:)),
            supersedes: supersedes
        )
    }
}
