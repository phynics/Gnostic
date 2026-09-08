// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Ascendant turn update replay")
struct AscendantTurnUpdateStoreTests {
    @Test("finishing the store closes its event stream")
    func finishingClosesEventStream() async throws {
        let store = AscendantTurnUpdateStore()
        let events = await store.events()
        let consumer = Task {
            var count = 0
            for await _ in events { count += 1 }
            return count
        }

        await store.finish()

        #expect(await consumer.value == 0)
    }

    @Test("retains ordered updates and reports terminal state")
    func orderedUpdates() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 4, maxBytes: 10_000)
        let timelineID = UUID()
        try await store.start(timelineID: timelineID, clientTurnID: "turn-1")
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn-1", kind: "assistant_text", text: "hello")
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn-1", kind: "completion", terminal: true)

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn-1")
        #expect(replay.updates.map(\.sequence) == [1, 2])
        #expect(replay.updates.last?.terminal == true)
        #expect(replay.terminal)
        #expect(!replay.compacted)
    }

    @Test("compaction retains an accumulated text snapshot and the newest update")
    func compaction() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 2, maxBytes: 10_000)
        let timelineID = UUID()
        try await store.start(timelineID: timelineID, clientTurnID: "turn-2")
        for index in 0..<4 {
            _ = try await store.append(timelineID: timelineID, clientTurnID: "turn-2", kind: "assistant_text", text: "\(index)")
        }

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn-2", afterSequence: 0)
        #expect(replay.compacted)
        #expect(replay.updates.count == 2)
        #expect(replay.updates.first?.kind == "assistant_text_snapshot")
        #expect(replay.updates.first?.text == "012")
        #expect(replay.updates.last?.text == "3")
    }

    @Test("compaction retains the authoritative terminal result")
    func terminalSurvivesCompaction() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 2, maxBytes: 10_000)
        let timelineID = UUID()
        try await store.start(timelineID: timelineID, clientTurnID: "turn-terminal")
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn-terminal", kind: "assistant_text", text: "a")
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn-terminal", kind: "assistant_text", text: "b")
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn-terminal", kind: "completion", text: "ab", terminal: true)

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn-terminal")
        #expect(replay.compacted)
        #expect(replay.updates.first?.kind == "assistant_text_snapshot")
        #expect(replay.updates.first?.text == "ab")
        #expect(replay.updates.last?.kind == "completion")
        #expect(replay.updates.last?.terminal == true)
    }

    @Test("compaction retains tool state snapshots")
    func toolStateSurvivesCompaction() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 2, maxBytes: 10_000)
        let timelineID = UUID()
        try await store.start(timelineID: timelineID, clientTurnID: "turn-tools")
        _ = try await store.append(
            timelineID: timelineID,
            clientTurnID: "turn-tools",
            kind: "tool_state",
            toolState: AscendantToolState(toolCallID: "call-1", title: "Read file", status: "in_progress")
        )
        _ = try await store.append(
            timelineID: timelineID,
            clientTurnID: "turn-tools",
            kind: "tool_state",
            toolState: AscendantToolState(toolCallID: "call-1", title: "Read file", status: "completed")
        )
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn-tools", kind: "assistant_text", text: "done")

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn-tools")
        #expect(replay.updates.first?.toolStates == [
            AscendantToolState(toolCallID: "call-1", title: "Read file", status: "completed")
        ])
        #expect(replay.updates.last?.text == "done")
    }

    @Test("retained updates obey the byte bound")
    func byteBound() async throws {
        let maxBytes = 512
        let store = AscendantTurnUpdateStore(maxEvents: 8, maxBytes: maxBytes)
        let timelineID = UUID()
        try await store.start(timelineID: timelineID, clientTurnID: "turn-bytes")
        for _ in 0..<4 {
            _ = try await store.append(
                timelineID: timelineID,
                clientTurnID: "turn-bytes",
                kind: "assistant_text",
                text: String(repeating: "🧭", count: 200)
            )
        }

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn-bytes")
        let retainedBytes = try replay.updates.reduce(0) { total, update in
            total + (try JSONEncoder().encode(update).count)
        }
        #expect(replay.compacted)
        #expect(retainedBytes <= maxBytes)
    }

    @Test("live events retain only the newest bounded buffer entries")
    func eventBufferIsBounded() async throws {
        let store = AscendantTurnUpdateStore(eventBufferCapacity: 2)
        let events = await store.events()
        let timelineID = UUID()
        try await store.start(timelineID: timelineID, clientTurnID: "buffered")
        for index in 0..<4 {
            _ = try await store.append(
                timelineID: timelineID,
                clientTurnID: "buffered",
                kind: "assistant_text",
                text: "event-\(index)"
            )
        }
        var iterator = events.makeAsyncIterator()
        var buffered: [AscendantTurnUpdateStore.Event] = []
        for _ in 0..<2 {
            if let event = await iterator.next() { buffered.append(event) }
        }
        #expect(buffered.count == 2)
        #expect(buffered.map { $0.update.text } == ["event-2", "event-3"])
    }

    @Test("active entries are not evicted, including after terminal append")
    func activeEntriesReserveCapacity() async throws {
        let store = AscendantTurnUpdateStore(maxEntries: 2)
        let firstTimeline = UUID()
        let secondTimeline = UUID()
        try await store.start(timelineID: firstTimeline, clientTurnID: "first")
        _ = try await store.append(timelineID: firstTimeline, clientTurnID: "first", kind: "completion", terminal: true)
        try await store.start(timelineID: secondTimeline, clientTurnID: "second")
        await #expect(throws: AscendantTurnUpdateStore.Error.self) {
            try await store.start(timelineID: UUID(), clientTurnID: "third")
        }
        try await store.finish(timelineID: firstTimeline, clientTurnID: "first")
        try await store.start(timelineID: UUID(), clientTurnID: "third")
        #expect((await store.retainedStateCounts).entries == 2)
    }

    @Test("public store operations reject invalid client turn ids")
    func invalidIDsAreReported() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        await #expect(throws: GnosticWirePayload.Error.self) {
            try await store.start(timelineID: timelineID, clientTurnID: "   ")
        }
        await #expect(throws: GnosticWirePayload.Error.self) {
            _ = try await store.append(timelineID: timelineID, clientTurnID: "", kind: "completion")
        }
        await #expect(throws: GnosticWirePayload.Error.self) {
            _ = try await store.replay(timelineID: timelineID, clientTurnID: "\n")
        }
    }

    @Test("retention is bounded globally across many turn ids")
    func globalRetentionBound() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 8, maxBytes: 10_000, maxEntries: 2)
        for index in 0..<8 {
            let timelineID = UUID()
            let clientTurnID = "turn-\(index)"
            try await store.start(timelineID: timelineID, clientTurnID: clientTurnID)
            _ = try await store.append(timelineID: timelineID, clientTurnID: clientTurnID, kind: "completion", terminal: true)
            try await store.finish(timelineID: timelineID, clientTurnID: clientTurnID)
        }

        let counts = await store.retainedStateCounts
        #expect(counts.entries <= 2)
        #expect(counts.bytes > 0)
    }

}
