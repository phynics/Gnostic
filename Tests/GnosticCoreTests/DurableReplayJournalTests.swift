// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

import GnosticCore

@Suite("Durable replay journal")
struct DurableReplayJournalTests {
    private struct Record: Codable, Sendable, Equatable {
        let id: Int
        let message: String
    }

    private enum ReplayError: Error, Equatable {
        case rejected(id: Int)
    }

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-replay-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    @Test("a journal replays its records through the supplied closure in order")
    func replaysInOrder() throws {
        let url = makeURL()
        let writer = DurableReplayJournal<Record>(fileURL: url)
        for index in 0..<3 {
            try writer.append(Record(id: index, message: "message-\(index)"))
        }

        var replayed: [Record] = []
        let reader = DurableReplayJournal<Record>(fileURL: url)
        try reader.recover { replayed.append($0) }
        #expect(replayed == [
            Record(id: 0, message: "message-0"),
            Record(id: 1, message: "message-1"),
            Record(id: 2, message: "message-2"),
        ])
    }

    @Test("a missing journal replays no records")
    func missingJournalReplaysNothing() throws {
        var replayed: [Record] = []
        let journal = DurableReplayJournal<Record>(fileURL: makeURL())
        try journal.recover { replayed.append($0) }
        #expect(replayed.isEmpty)
    }

    @Test("a throwing replay surfaces to the caller")
    func throwingReplaySurfaces() throws {
        let url = makeURL()
        let writer = DurableReplayJournal<Record>(fileURL: url)
        try writer.append(Record(id: 1, message: "one"))
        try writer.append(Record(id: 2, message: "two"))

        let reader = DurableReplayJournal<Record>(fileURL: url)
        #expect(throws: ReplayError.rejected(id: 2)) {
            try reader.recover { record in
                guard record.id != 2 else { throw ReplayError.rejected(id: record.id) }
            }
        }
    }

    @Test("a journal reports its byte count and replaces its contents")
    func byteCountAndReplaceAll() throws {
        let url = makeURL()
        let journal = DurableReplayJournal<Record>(fileURL: url)
        try journal.append(Record(id: 1, message: "one"))
        let single = try journal.byteCount()
        #expect(single > 0)

        try journal.replaceAll(with: [Record(id: 2, message: "two"), Record(id: 3, message: "three")])
        var replayed: [Record] = []
        try journal.recover { replayed.append($0) }
        #expect(replayed.map(\.id) == [2, 3])
    }
}
