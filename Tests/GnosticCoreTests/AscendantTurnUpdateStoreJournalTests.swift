// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Ascendant turn update journal")
struct AscendantTurnUpdateStoreJournalTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ascendant-turn-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("turn-events.jsonl")
    }

    @Test("a restarted store replays journaled turns")
    func restartReplaysTurns() async throws {
        let url = makeURL()
        let timelineID = UUID()
        let writer = AscendantTurnUpdateStore()
        try await writer.enableDurability(at: url)
        try await writer.start(timelineID: timelineID, clientTurnID: "turn-1", message: "hello")
        _ = try await writer.append(timelineID: timelineID, clientTurnID: "turn-1", kind: "assistant_text", text: "hi")
        _ = try await writer.append(timelineID: timelineID, clientTurnID: "turn-1", kind: "completion", text: "hi", terminal: true)
        try await writer.finish(timelineID: timelineID, clientTurnID: "turn-1")

        let reader = AscendantTurnUpdateStore()
        try await reader.enableDurability(at: url)
        let replay = try await reader.replay(timelineID: timelineID, clientTurnID: "turn-1", message: "hello")
        #expect(replay.updates.map(\.sequence) == [1, 2])
        #expect(replay.updates.map(\.text) == ["hi", "hi"])
        #expect(replay.terminal)
        #expect(!replay.conflict)
    }

    @Test("recovery preserves compaction")
    func recoveryPreservesCompaction() async throws {
        let url = makeURL()
        let timelineID = UUID()
        let writer = AscendantTurnUpdateStore(maxEvents: 2, maxBytes: 10_000)
        try await writer.enableDurability(at: url)
        try await writer.start(timelineID: timelineID, clientTurnID: "turn-2")
        for index in 0..<4 {
            _ = try await writer.append(timelineID: timelineID, clientTurnID: "turn-2", kind: "assistant_text", text: "\(index)")
        }

        let reader = AscendantTurnUpdateStore(maxEvents: 2, maxBytes: 10_000)
        try await reader.enableDurability(at: url)
        let replay = try await reader.replay(timelineID: timelineID, clientTurnID: "turn-2")
        #expect(replay.compacted)
        #expect(replay.updates.count == 2)
        #expect(replay.updates.first?.kind == "assistant_text_snapshot")
        #expect(replay.updates.first?.text == "012")
        #expect(replay.updates.last?.text == "3")
    }

    @Test("recovery keeps the message digest for conflict detection")
    func recoveryKeepsMessageDigest() async throws {
        let url = makeURL()
        let timelineID = UUID()
        let writer = AscendantTurnUpdateStore()
        try await writer.enableDurability(at: url)
        try await writer.start(timelineID: timelineID, clientTurnID: "turn-3", message: "hello")
        _ = try await writer.append(timelineID: timelineID, clientTurnID: "turn-3", kind: "assistant_text", text: "hi")

        let reader = AscendantTurnUpdateStore()
        try await reader.enableDurability(at: url)
        let conflict = try await reader.replay(timelineID: timelineID, clientTurnID: "turn-3", message: "different")
        #expect(conflict.conflict)
        #expect(conflict.updates.isEmpty)
    }

    @Test("recovery skips a start beyond the live retention bound")
    func recoverySkipsCapacityOverflow() async throws {
        let url = makeURL()
        let writer = AscendantTurnUpdateStore(maxEntries: 5)
        try await writer.enableDurability(at: url)
        let timelines = (0..<3).map { _ in UUID() }
        for (index, timelineID) in timelines.enumerated() {
            try await writer.start(timelineID: timelineID, clientTurnID: "turn-\(index)")
            _ = try await writer.append(timelineID: timelineID, clientTurnID: "turn-\(index)", kind: "assistant_text", text: "\(index)")
        }

        let reader = AscendantTurnUpdateStore(maxEntries: 2)
        try await reader.enableDurability(at: url)
        #expect(try await reader.replay(timelineID: timelines[0], clientTurnID: "turn-0").updates.map(\.text) == ["0"])
        #expect(try await reader.replay(timelineID: timelines[1], clientTurnID: "turn-1").updates.map(\.text) == ["1"])
        #expect(try await reader.replay(timelineID: timelines[2], clientTurnID: "turn-2").updates.isEmpty)
    }

    @Test("turn event records round trip through JSON")
    func recordRoundTrip() throws {
        let timelineID = UUID()
        let records: [TurnEventRecord] = [
            TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .started(messageDigest: 42)),
            TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .update(
                AscendantTurnUpdate(sequence: 1, kind: "assistant_text", text: "hi")
            )),
            TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .finished),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for record in records {
            let decoded = try decoder.decode(TurnEventRecord.self, from: try encoder.encode(record))
            #expect(decoded == record)
        }
    }
}
