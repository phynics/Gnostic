// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticPositronicContext

@Suite("Flat context checkpoint synthesis")
struct ContextCheckpointTests {
    private let ascendantID = "asc-1"
    private let timelineID = "tl-checkpoint"

    // MARK: Planning

    @Test("the planner covers the prefix exactly with every accepted leaf")
    func plannerCoversPrefixExactly() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let nodes = try await curatedLeaves(transcript)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 1
        )
        #expect(checkpoint.coveredNodeIDs == nodes.map(\.id))
        #expect(checkpoint.sourceRange.messageIDs == messages.map(\.id))
        #expect(checkpoint.throughMessageID == through)
        #expect(checkpoint.ascendantID == ascendantID)
        #expect(checkpoint.timelineID == timelineID)
        #expect(checkpoint.exactPins.isEmpty)
    }

    @Test("a cut that splits a tool transaction is rejected")
    func toolTransactionSplitIsRejected() async throws {
        let transcript = ContextTranscript(turns: [
            ContextTurn(index: 0, role: .user, text: "Read the broker configuration."),
            ContextTurn(index: 1, role: .assistant, text: "I will call the configuration reader tool."),
            ContextTurn(index: 2, role: .tool, text: "Tool result: the configuration was read."),
            ContextTurn(index: 3, role: .user, text: "Good. Record the port."),
        ])
        let nodes = try await curatedLeaves(transcript, episodeSize: 2)
        let messages = history(from: transcript)
        let cut = try #require(throughID(messages, "turn-000001"))
        #expect(throws: ContextError.toolTransactionSplit) {
            try planner().plan(
                ascendantID: ascendantID,
                timelineID: timelineID,
                messages: messages,
                leaves: nodes,
                throughMessageID: cut,
                revision: 1
            )
        }
        // The same history cut after the tool result, on an episode boundary,
        // is accepted.
        let whole = try #require(throughID(messages, "turn-000003"))
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: whole,
            revision: 1
        )
        #expect(checkpoint.sourceRange.messageIDs == messages.map(\.id))
    }

    @Test("a cut inside a leaf's coverage is rejected as a cover gap")
    func midLeafCutIsRejected() async throws {
        let transcript = alternatingTranscript(count: 6)
        let nodes = try await curatedLeaves(transcript, episodeSize: 2)
        let messages = history(from: transcript)
        let cut = try #require(throughID(messages, "turn-000004"))
        #expect(throws: ContextError.coverageGap) {
            try planner().plan(
                ascendantID: ascendantID,
                timelineID: timelineID,
                messages: messages,
                leaves: nodes,
                throughMessageID: cut,
                revision: 1
            )
        }
    }

    @Test("a partial cut through complete episodes plans a partial checkpoint")
    func partialCutPlansPartialCheckpoint() async throws {
        let transcript = alternatingTranscript(count: 6)
        let nodes = try await curatedLeaves(transcript, episodeSize: 2)
        let messages = history(from: transcript)
        let cut = try #require(throughID(messages, "turn-000003"))
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: cut,
            revision: 1
        )
        #expect(checkpoint.coveredNodeIDs == nodes.prefix(2).map(\.id))
        #expect(checkpoint.sourceRange.messageIDs == messages.prefix(4).map(\.id))
        #expect(checkpoint.throughMessageID == cut)
    }

    @Test("checkpoint carry is the deterministic reduction and the renderer projects it")
    func carryReductionAndRenderer() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let nodes = try await curatedLeaves(transcript)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 3
        )
        let reduced = ContextCarryReducer().reduce(nodes.map(\.carry))
        #expect(checkpoint.carry == reduced)
        #expect(checkpoint.revision == 3)
        #expect(checkpoint.curatorVersion == ContextCheckpointPlanner.version)
        // The default projection is exactly the gate `incremental-flat` arm:
        // the active carry texts joined by newline, no headers, no model prose.
        #expect(
            ContextCheckpointRenderer().render(checkpoint)
                == reduced.activeItems.map(\.text).joined(separator: "\n")
        )
    }

    @Test("planning is order-independent and regenerates identically")
    func regenerationIsDeterministic() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let nodes = try await curatedLeaves(transcript)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        let first = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 7
        )
        let second = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes.reversed(),
            throughMessageID: through,
            revision: 7
        )
        #expect(first == second)
        #expect(first.id == second.id)
        // The revision is activation bookkeeping, not content: minting the
        // same cover again at another revision shares identity and body.
        let reissued = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 9
        )
        #expect(reissued.id == first.id)
        #expect(reissued == first)
    }

    // MARK: Validation

    @Test("a valid checkpoint validates against its stored leaves")
    func validCheckpointValidates() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let nodes = try await curatedLeaves(transcript)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 1
        )
        let validated = try ContextCheckpointValidator().validate(checkpoint, leaves: nodes)
        #expect(validated == checkpoint)
    }

    @Test("a missing required carry item rejects the candidate")
    func missingCarryItemIsRejected() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let nodes = try await curatedLeaves(transcript)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 1
        )
        let trimmed = reissuing(checkpoint, carry: ContextCarryState(items: Array(checkpoint.carry.items.dropFirst())))
        #expect(trimmed.id == checkpoint.id)
        #expect(throws: ContextError.carrySurvivalFailed) {
            try ContextCheckpointValidator().validate(trimmed, leaves: nodes)
        }
    }

    @Test("an exact pin cannot disappear from the checkpoint")
    func exactPinSurvival() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        // Host pins are policy, not transcript evidence, so they cite no
        // message. The text is distinct from every fixture item, so a bare
        // checkpoint cannot satisfy the pin by accident. Pins ride the
        // leaves: the leaf validator merges them into every episode, the
        // reducer deduplicates them by ID, and the checkpoint validator
        // enforces their survival.
        let pin = ContextCarryItem(
            id: "pin-operator-port",
            category: .exactPins,
            text: "Host pin: the operator requires the broker port to stay 8317.",
            origin: .systemConstraint,
            epistemicStatus: .asserted,
            citations: []
        )
        let pinnedNodes = try await curatedLeaves(transcript, hostPins: [pin])
        let pinnedCheckpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: pinnedNodes,
            throughMessageID: through,
            revision: 1
        )
        #expect(pinnedCheckpoint.exactPins.count == 1)
        _ = try ContextCheckpointValidator(hostPins: [pin]).validate(pinnedCheckpoint, leaves: pinnedNodes)

        // A checkpoint whose leaves never carried the pin fails survival.
        let bareNodes = try await curatedLeaves(transcript)
        let bareCheckpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: bareNodes,
            throughMessageID: through,
            revision: 1
        )
        #expect(throws: ContextError.carrySurvivalFailed) {
            try ContextCheckpointValidator(hostPins: [pin]).validate(bareCheckpoint, leaves: bareNodes)
        }
    }

    @Test("an oversized synopsis is rejected")
    func oversizedSynopsisIsRejected() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let nodes = try await curatedLeaves(transcript)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 1
        )
        let bloated = reissuing(
            checkpoint,
            synopsis: String(repeating: "s", count: ContextDescriptor.default.maxSynopsisBytes + 1)
        )
        #expect(throws: ContextError.budgetExceeded) {
            try ContextCheckpointValidator().validate(bloated, leaves: nodes)
        }
    }

    @Test("a record whose cut disagrees with its coverage is rejected")
    func cutDisagreeingWithCoverageIsRejected() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let nodes = try await curatedLeaves(transcript)
        let messages = history(from: transcript)
        let through = try #require(messages.last?.id)
        let checkpoint = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: through,
            revision: 1
        )
        let mismatched = reissuing(checkpoint, throughMessageID: messages[2].id)
        #expect(throws: ContextError.unknownSourceRange) {
            try ContextCheckpointValidator().validate(mismatched, leaves: nodes)
        }
    }

    @Test("a different source cut cannot reuse the checkpoint")
    func differentCutCannotReuseCheckpoint() async throws {
        let transcript = alternatingTranscript(count: 6)
        let nodes = try await curatedLeaves(transcript, episodeSize: 2)
        let messages = history(from: transcript)
        let earlyCut = try #require(throughID(messages, "turn-000001"))
        let lateCut = try #require(throughID(messages, "turn-000003"))
        let early = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: earlyCut,
            revision: 1
        )
        let late = try planner().plan(
            ascendantID: ascendantID,
            timelineID: timelineID,
            messages: messages,
            leaves: nodes,
            throughMessageID: lateCut,
            revision: 1
        )
        #expect(early.id != late.id)
        #expect(early.coveredNodeIDs != late.coveredNodeIDs)
        #expect(early.sourceRange != late.sourceRange)
        // Both records stay distinct in the store; neither body can hide
        // under the other's identity.
        let store = InMemoryContextStore()
        let key = ContextStoreKey(ascendantID: ascendantID, timelineID: timelineID)
        try await store.insertCheckpoint(early, for: key)
        try await store.insertCheckpoint(late, for: key)
        #expect(await store.checkpoint(id: early.id, for: key) == early)
        #expect(await store.checkpoint(id: late.id, for: key) == late)
    }

    // MARK: Fixtures

    private func planner() -> ContextCheckpointPlanner {
        ContextCheckpointPlanner()
    }

    /// Reissues one checkpoint with substituted body fields.
    ///
    /// The identity inputs stay untouched, so a reissued record shares the
    /// original identity whenever only the body changed, exactly like a
    /// curator trying to smuggle a different body under a known identity.
    private func reissuing(
        _ checkpoint: ContextCheckpoint,
        throughMessageID: String? = nil,
        synopsis: String? = nil,
        carry: ContextCarryState? = nil
    ) -> ContextCheckpoint {
        ContextCheckpoint(
            ascendantID: checkpoint.ascendantID,
            timelineID: checkpoint.timelineID,
            throughMessageID: throughMessageID ?? checkpoint.throughMessageID,
            sourceRange: checkpoint.sourceRange,
            coveredNodeIDs: checkpoint.coveredNodeIDs,
            synopsis: synopsis ?? checkpoint.synopsis,
            carry: carry ?? checkpoint.carry,
            curatorVersion: checkpoint.curatorVersion,
            revision: checkpoint.revision
        )
    }

    private func throughID(_ messages: [ContextMessage], _ id: String) -> String? {
        messages.first { $0.id == "m-\(id)" }?.id
    }

    private func history(from transcript: ContextTranscript) -> [ContextMessage] {
        transcript.turns.map {
            ContextMessage(id: ContextMessage.id(forTurnIndex: $0.index), role: $0.role, text: $0.text)
        }
    }

    /// Validates one leaf proposal per episode, threading the accepted carry,
    /// exactly like the offline gate's curation loop.
    private func curatedLeaves(
        _ transcript: ContextTranscript,
        episodeSize: Int = 2,
        hostPins: [ContextCarryItem] = []
    ) async throws -> [ContextNode] {
        let replay = ContextEpisodeReplay(timelineID: timelineID, episodeSize: episodeSize)
        let leaves = try await replay.replay(
            transcript: transcript,
            descriptor: .default,
            curator: FixtureContextCurator()
        )
        let validator = ContextProposalValidator(hostPins: hostPins)
        var active = ContextCarryState()
        var nodes: [ContextNode] = []
        for leaf in leaves {
            let node = try validator.validate(leaf, expectedTimelineID: timelineID, activeCarry: active)
            nodes.append(node)
            active = ContextCarryState(items: active.items + node.carry.items)
        }
        return nodes
    }

    private func alternatingTranscript(count: Int) -> ContextTranscript {
        ContextTranscript(
            turns: (0..<count).map { index in
                ContextTurn(
                    index: index,
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: "Turn \(index) of the alternating history."
                )
            }
        )
    }
}
