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

    @Test("compaction keeps the journal within its byte bound and preserves recovery")
    func compactionBoundsJournal() async throws {
        let url = makeURL()
        let timelineID = UUID()
        let maxJournalBytes = 2_048
        let writer = AscendantTurnUpdateStore(maxEvents: 4, maxBytes: 900, maxJournalBytes: maxJournalBytes)
        try await writer.enableDurability(at: url)
        try await writer.start(timelineID: timelineID, clientTurnID: "turn-bound", message: "hello")
        for index in 0..<300 {
            _ = try await writer.append(
                timelineID: timelineID,
                clientTurnID: "turn-bound",
                kind: "assistant_text",
                text: "chunk-\(index)-" + String(repeating: "x", count: 64)
            )
        }
        #expect(try fileSize(url) <= UInt64(maxJournalBytes))
        let expected = try await writer.replay(
            timelineID: timelineID, clientTurnID: "turn-bound", message: "hello"
        )

        let reader = AscendantTurnUpdateStore(maxEvents: 4, maxBytes: 900, maxJournalBytes: maxJournalBytes)
        try await reader.enableDurability(at: url)
        let actual = try await reader.replay(
            timelineID: timelineID, clientTurnID: "turn-bound", message: "hello"
        )
        #expect(actual.updates.map(\.sequence) == expected.updates.map(\.sequence))
        #expect(actual.updates.map(\.kind) == expected.updates.map(\.kind))
        #expect(actual.updates.map(\.text) == expected.updates.map(\.text))
        #expect(actual.compacted == expected.compacted)
        #expect(actual.terminal == expected.terminal)
    }

    @Test("compaction preserves the message digest for conflict detection")
    func compactionKeepsMessageDigest() async throws {
        let url = makeURL()
        let timelineID = UUID()
        let writer = AscendantTurnUpdateStore(maxEvents: 4, maxBytes: 900, maxJournalBytes: 1_024)
        try await writer.enableDurability(at: url)
        try await writer.start(timelineID: timelineID, clientTurnID: "turn-digest", message: "hello")
        for index in 0..<200 {
            _ = try await writer.append(
                timelineID: timelineID, clientTurnID: "turn-digest", kind: "assistant_text",
                text: "chunk-\(index)-" + String(repeating: "y", count: 64)
            )
        }

        let reader = AscendantTurnUpdateStore(maxEvents: 4, maxBytes: 900, maxJournalBytes: 1_024)
        try await reader.enableDurability(at: url)
        let conflict = try await reader.replay(
            timelineID: timelineID, clientTurnID: "turn-digest", message: "different"
        )
        #expect(conflict.conflict)
        #expect(conflict.updates.isEmpty)
    }

    @Test("recovery skips a checkpoint beyond the live retention bound")
    func recoverySkipsCheckpointOverflow() async throws {
        let url = makeURL()
        let timelines = (0..<3).map { _ in UUID() }
        let log = AppendOnlyEventLog<TurnEventRecord>(fileURL: url)
        for (index, timelineID) in timelines.enumerated() {
            try log.append(TurnEventRecord(
                timelineID: timelineID,
                clientTurnID: "turn-\(index)",
                event: .checkpoint(TurnJournalCheckpoint(
                    messageDigest: nil,
                    nextSequence: 2,
                    updates: [AscendantTurnUpdate(sequence: 1, kind: "assistant_text", text: "\(index)")],
                    compacted: false,
                    terminal: false,
                    finished: false
                ))
            ))
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
            TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .checkpoint(
                TurnJournalCheckpoint(
                    messageDigest: 42,
                    nextSequence: 2,
                    updates: [AscendantTurnUpdate(sequence: 1, kind: "assistant_text", text: "hi")],
                    compacted: false,
                    terminal: false,
                    finished: true
                )
            )),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for record in records {
            let decoded = try decoder.decode(TurnEventRecord.self, from: try encoder.encode(record))
            #expect(decoded == record)
        }
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
