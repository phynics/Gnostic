// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit
import Testing

@testable import GnosticPositronicContext

@Suite("Context models and in-memory store")
struct ContextStoreTests {
    private let key = ContextStoreKey(ascendantID: "asc-1", timelineID: "tl-1")

    @Test("duplicate insertion with the same body is idempotent")
    func duplicateInsertionIsIdempotent() async throws {
        let store = InMemoryContextStore()
        let node = leaf(messageIDs: ["m-0", "m-1"])
        try await store.insert(node, for: key)
        try await store.insert(node, for: key)
        #expect(await store.acceptedNodes(for: key).count == 1)
    }

    @Test("a different body for the same content-addressed ID is a conflict")
    func conflictingBodyForSameIDThrows() async throws {
        let store = InMemoryContextStore()
        let coverage = ContextSourceRange.hostComputed(timelineID: "tl-1", messageIDs: ["m-0"])
        let first = ContextNode(
            timelineID: "tl-1",
            coverage: coverage,
            carry: ContextCarryState(items: [carryItem(id: "a")]),
            curatorVersion: "fixture-v1"
        )
        let second = ContextNode(
            timelineID: "tl-1",
            coverage: coverage,
            carry: ContextCarryState(items: [carryItem(id: "b")]),
            curatorVersion: "fixture-v1"
        )
        #expect(first.id == second.id)
        try await store.insert(first, for: key)
        await #expect(throws: ContextError.conflictingBody) {
            try await store.insert(second, for: key)
        }
    }

    @Test("the curator version is provenance, not identity")
    func curatorVersionDoesNotAffectIdentity() async throws {
        let store = InMemoryContextStore()
        let coverage = ContextSourceRange.hostComputed(timelineID: "tl-1", messageIDs: ["m-0"])
        let first = ContextNode(timelineID: "tl-1", coverage: coverage, curatorVersion: "fixture-v1")
        let second = ContextNode(timelineID: "tl-1", coverage: coverage, curatorVersion: "llm-v1")
        #expect(first.id == second.id)
        try await store.insert(first, for: key)
        try await store.insert(second, for: key)
        let storedOptional = await store.node(id: first.id, for: key)
        let stored = try #require(storedOptional)
        #expect(stored.curatorVersion == "fixture-v1")
    }

    @Test("a node that names another Timeline is rejected")
    func crossTimelineNodeIsRejected() async throws {
        let store = InMemoryContextStore()
        let node = ContextNode(
            timelineID: "tl-2",
            coverage: ContextSourceRange.hostComputed(timelineID: "tl-2", messageIDs: ["m-0"]),
            curatorVersion: "fixture-v1"
        )
        await #expect(throws: ContextError.crossTimeline) {
            try await store.insert(node, for: key)
        }
    }

    @Test("a coverage range from another Timeline is rejected")
    func crossTimelineCoverageIsRejected() async throws {
        let store = InMemoryContextStore()
        let node = ContextNode(
            timelineID: "tl-1",
            coverage: ContextSourceRange.hostComputed(timelineID: "tl-2", messageIDs: ["m-0"]),
            curatorVersion: "fixture-v1"
        )
        await #expect(throws: ContextError.crossTimeline) {
            try await store.insert(node, for: key)
        }
    }

    @Test("empty coverage is rejected")
    func emptyCoverageIsRejected() async throws {
        let store = InMemoryContextStore()
        let node = ContextNode(
            timelineID: "tl-1",
            coverage: ContextSourceRange(timelineID: "tl-1", messageIDs: [], digest: "digest"),
            curatorVersion: "fixture-v1"
        )
        await #expect(throws: ContextError.unknownSourceRange) {
            try await store.insert(node, for: key)
        }
    }

    @Test("the store partitions by Ascendant and Timeline")
    func partitionsByAscendantAndTimeline() async throws {
        let store = InMemoryContextStore()
        let node = leaf(messageIDs: ["m-0"])
        try await store.insert(node, for: key)
        let otherAscendant = ContextStoreKey(ascendantID: "asc-2", timelineID: "tl-1")
        let otherTimeline = ContextStoreKey(ascendantID: "asc-1", timelineID: "tl-2")
        #expect(await store.acceptedNodes(for: otherAscendant).isEmpty)
        #expect(await store.acceptedNodes(for: otherTimeline).isEmpty)
        #expect(await store.acceptedNodes(for: key).count == 1)
    }

    @Test("roots exclude nodes that appear as children")
    func rootsExcludeChildren() async throws {
        let store = InMemoryContextStore()
        let coverage = ContextSourceRange.hostComputed(timelineID: "tl-1", messageIDs: ["m-0"])
        let child = ContextNode(timelineID: "tl-1", coverage: coverage, curatorVersion: "fixture-v1")
        let parent = ContextNode(
            timelineID: "tl-1",
            coverage: coverage,
            children: [child.id],
            curatorVersion: "fixture-v1"
        )
        try await store.insert(child, for: key)
        try await store.insert(parent, for: key)
        #expect(await store.rootNodeIDs(for: key) == [parent.id])
    }

    @Test("checkpoint candidates are idempotent and must name a stored node")
    func checkpointCandidatesAreIdempotent() async throws {
        let store = InMemoryContextStore()
        let node = leaf(messageIDs: ["m-0"])
        try await store.insert(node, for: key)
        try await store.insertCheckpointCandidate(node.id, for: key)
        try await store.insertCheckpointCandidate(node.id, for: key)
        #expect(await store.checkpointCandidates(for: key) == [node.id])
        await #expect(throws: ContextError.unknownSourceRange) {
            try await store.insertCheckpointCandidate("missing", for: key)
        }
    }

    @Test("checkpoint insertion is idempotent and a conflicting body is a conflict")
    func checkpointInsertionIsIdempotent() async throws {
        let store = InMemoryContextStore()
        let checkpoint = makeCheckpoint(coveredNodeIDs: ["n-0"])
        try await store.insertCheckpoint(checkpoint, for: key)
        try await store.insertCheckpoint(checkpoint, for: key)
        #expect(await store.checkpoint(id: checkpoint.id, for: key) == checkpoint)
        let conflicting = makeCheckpoint(
            coveredNodeIDs: ["n-0"],
            carry: ContextCarryState(items: [carryItem(id: "a")])
        )
        #expect(conflicting.id == checkpoint.id)
        await #expect(throws: ContextError.conflictingBody) {
            try await store.insertCheckpoint(conflicting, for: key)
        }
    }

    @Test("the active checkpoint resolves, must exist, and clears")
    func activeCheckpointResolves() async throws {
        let store = InMemoryContextStore()
        let checkpoint = makeCheckpoint(coveredNodeIDs: ["n-0"])
        try await store.insertCheckpoint(checkpoint, for: key)
        try await store.setActiveCheckpoint(checkpoint.id, for: key)
        #expect(await store.activeCheckpointID(for: key) == checkpoint.id)
        #expect(await store.activeCheckpoint(for: key) == checkpoint)
        try await store.setActiveCheckpoint(nil, for: key)
        #expect(await store.activeCheckpoint(for: key) == nil)
        await #expect(throws: ContextError.unknownSourceRange) {
            try await store.setActiveCheckpoint("missing", for: key)
        }
    }

    @Test("checkpoints partition with their Ascendant and Timeline")
    func checkpointsPartitionByStoreKey() async throws {
        let store = InMemoryContextStore()
        let checkpoint = makeCheckpoint(coveredNodeIDs: ["n-0"])
        try await store.insertCheckpoint(checkpoint, for: key)
        let otherAscendant = ContextStoreKey(ascendantID: "asc-2", timelineID: "tl-1")
        #expect(await store.checkpoint(id: checkpoint.id, for: otherAscendant) == nil)
        let foreign = makeCheckpoint(timelineID: "tl-2", coveredNodeIDs: ["n-0"])
        await #expect(throws: ContextError.crossTimeline) {
            try await store.insertCheckpoint(foreign, for: key)
        }
    }

    @Test("the projection revision advances monotonically")
    func projectionRevisionAdvances() async throws {
        let store = InMemoryContextStore()
        #expect(await store.projectionRevision(for: key) == 0)
        #expect(await store.advanceProjectionRevision(for: key) == 1)
        #expect(await store.advanceProjectionRevision(for: key) == 2)
    }

    @Test("the host computes the source digest")
    func hostComputesSourceDigest() {
        let range = ContextSourceRange.hostComputed(timelineID: "tl-1", messageIDs: ["m-0", "m-1"])
        #expect(range.digest == ContextHashing.digest(["tl-1", "m-0", "m-1"]))
        #expect(range.firstMessageID == "m-0")
        #expect(range.lastMessageID == "m-1")
    }

    @Test("dropping the store cannot affect conversation history")
    func droppingStoreDoesNotAffectHistory() async throws {
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 1)
        let store = InMemoryContextStore()
        try await store.insert(leaf(messageIDs: ["m-0"]), for: key)
        await store.removeAll()
        #expect(await store.acceptedNodes(for: key).isEmpty)
        #expect(transcript.turns.count > 0)
        #expect(transcript.rendered.contains("port 8317"))
    }

    private func leaf(messageIDs: [String], carry: ContextCarryState = ContextCarryState()) -> ContextNode {
        ContextNode(
            timelineID: "tl-1",
            coverage: ContextSourceRange.hostComputed(timelineID: "tl-1", messageIDs: messageIDs),
            carry: carry,
            curatorVersion: "fixture-v1"
        )
    }

    private func makeCheckpoint(
        timelineID: String = "tl-1",
        coveredNodeIDs: [String],
        carry: ContextCarryState = ContextCarryState()
    ) -> ContextCheckpoint {
        ContextCheckpoint(
            ascendantID: "asc-1",
            timelineID: timelineID,
            throughMessageID: "m-1",
            sourceRange: ContextSourceRange.hostComputed(timelineID: timelineID, messageIDs: ["m-0", "m-1"]),
            coveredNodeIDs: coveredNodeIDs,
            carry: carry,
            curatorVersion: "checkpoint-v1",
            revision: 1
        )
    }

    private func carryItem(id: String) -> ContextCarryItem {
        ContextCarryItem(
            id: id,
            category: .facts,
            text: "fact \(id)",
            origin: .userStatement,
            epistemicStatus: .asserted,
            citations: [ContextCitation(messageID: "m-0")]
        )
    }
}
