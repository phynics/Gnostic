// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import GnosticPositronicBackend

@testable import GnosticPositronicContext

@Suite("Context store durable journal")
struct ContextStoreJournalTests {
    private let key = ContextStoreKey(ascendantID: "asc-1", timelineID: "tl-1")

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("context-store-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("context.jsonl")
    }

    @Test("a restarted store replays nodes, checkpoints, and the projection revision")
    func restartReplaysState() async throws {
        let url = makeURL()
        let writer = InMemoryContextStore()
        try await writer.enableDurability(at: url)
        let node = leaf(messageIDs: ["m-0"])
        let checkpoint = makeCheckpoint(coveredNodeIDs: [node.id])
        try await writer.insert(node, for: key)
        try await writer.insertCheckpointCandidate(node.id, for: key)
        try await writer.insertCheckpoint(checkpoint, for: key)
        try await writer.setActiveCheckpoint(checkpoint.id, for: key)
        #expect(await writer.advanceProjectionRevision(for: key) == 1)
        #expect(await writer.advanceProjectionRevision(for: key) == 2)

        let reader = InMemoryContextStore()
        try await reader.enableDurability(at: url)

        #expect(await reader.acceptedNodes(for: key) == [node])
        #expect(await reader.checkpointCandidates(for: key) == [node.id])
        #expect(await reader.checkpoint(id: checkpoint.id, for: key) == checkpoint)
        #expect(await reader.activeCheckpointID(for: key) == checkpoint.id)
        #expect(await reader.activeCheckpoint(for: key) == checkpoint)
        #expect(await reader.projectionRevision(for: key) == 2)
        #expect(await reader.node(id: node.id, for: key) == node)
        #expect(await reader.rootNodeIDs(for: key) == [node.id])
    }

    @Test("a restarted store replays a cleared active checkpoint")
    func restartReplaysClearedCheckpoint() async throws {
        let url = makeURL()
        let writer = InMemoryContextStore()
        try await writer.enableDurability(at: url)
        let node = leaf(messageIDs: ["m-0"])
        let checkpoint = makeCheckpoint(coveredNodeIDs: [node.id])
        try await writer.insert(node, for: key)
        try await writer.insertCheckpoint(checkpoint, for: key)
        try await writer.setActiveCheckpoint(checkpoint.id, for: key)
        try await writer.setActiveCheckpoint(nil, for: key)

        let reader = InMemoryContextStore()
        try await reader.enableDurability(at: url)
        #expect(await reader.checkpoint(id: checkpoint.id, for: key) == checkpoint)
        #expect(await reader.activeCheckpointID(for: key) == nil)
        #expect(await reader.activeCheckpoint(for: key) == nil)
    }

    @Test("removing every partition is journaled")
    func removeAllIsJournaled() async throws {
        let url = makeURL()
        let writer = InMemoryContextStore()
        try await writer.enableDurability(at: url)
        try await writer.insert(leaf(messageIDs: ["m-0"]), for: key)
        await writer.removeAll()

        let reader = InMemoryContextStore()
        try await reader.enableDurability(at: url)
        #expect(await reader.acceptedNodes(for: key).isEmpty)
    }

    @Test("recovery keeps the valid prefix and drops a torn tail")
    func recoveryDropsTornTail() async throws {
        let url = makeURL()
        let writer = InMemoryContextStore()
        try await writer.enableDurability(at: url)
        let first = leaf(messageIDs: ["m-0"])
        let second = leaf(messageIDs: ["m-1"])
        try await writer.insert(first, for: key)
        try await writer.insert(second, for: key)

        let data = try Data(contentsOf: url)
        try Data(data.dropLast(12)).write(to: url)

        let reader = InMemoryContextStore()
        try await reader.enableDurability(at: url)
        #expect(await reader.acceptedNodes(for: key) == [first])

        // The store keeps accepting mutations after recovery.
        try await reader.insert(second, for: key)
        #expect(await reader.acceptedNodes(for: key).count == 2)
    }

    @Test("journal events round-trip through JSON")
    func journalEventsRoundTrip() throws {
        let node = leaf(messageIDs: ["m-0"])
        let checkpoint = makeCheckpoint(coveredNodeIDs: [node.id])
        let events: [ContextStoreEvent] = [
            .inserted(node, key),
            .checkpointCandidate(node.id, key),
            .checkpointInserted(checkpoint, key),
            .activeCheckpoint(checkpoint.id, key),
            .activeCheckpoint(nil, key),
            .projectionRevision(3, key),
            .removedAll,
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(ContextStoreEvent.self, from: data)
            #expect(decoded == event)
        }
    }

    private func leaf(messageIDs: [String]) -> ContextNode {
        ContextNode(
            timelineID: "tl-1",
            coverage: ContextSourceRange.hostComputed(timelineID: "tl-1", messageIDs: messageIDs),
            curatorVersion: "fixture-v1"
        )
    }

    private func makeCheckpoint(coveredNodeIDs: [String]) -> ContextCheckpoint {
        ContextCheckpoint(
            ascendantID: "asc-1",
            timelineID: "tl-1",
            throughMessageID: "m-0",
            sourceRange: ContextSourceRange.hostComputed(timelineID: "tl-1", messageIDs: ["m-0"]),
            coveredNodeIDs: coveredNodeIDs,
            curatorVersion: "checkpoint-v1",
            revision: 1
        )
    }
}
