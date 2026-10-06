// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Append-only event log")
struct AppendOnlyEventLogTests {
    private struct Record: Codable, Sendable, Equatable {
        let id: Int
        let message: String
    }

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("append-only-event-log-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    @Test("records survive a round trip through the file")
    func roundTrip() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        for index in 0..<3 {
            try log.append(Record(id: index, message: "message-\(index)"))
        }

        let recovered = try log.recover()
        #expect(recovered.map(\.payload) == [
            Record(id: 0, message: "message-0"),
            Record(id: 1, message: "message-1"),
            Record(id: 2, message: "message-2"),
        ])
        #expect(recovered[1].recordedAt >= recovered[0].recordedAt)
    }

    @Test("a missing file recovers no records")
    func missingFile() throws {
        let log = AppendOnlyEventLog<Record>(fileURL: makeURL())
        #expect(try log.recover().isEmpty)
    }

    @Test("the log creates its parent directory")
    func createsParentDirectory() throws {
        let url = makeURL()
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("recovery drops and truncates a torn tail")
    func tornTailRecovery() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        let validSize = try fileSize(url)
        // Simulate a crash mid-write: no trailing newline and a bad checksum.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("deadbeef 1700000000000 {\"id\":2,\"message\":\"two\"}".utf8))
        try handle.close()

        let recovered = try log.recover()
        #expect(recovered.map(\.payload) == [Record(id: 1, message: "one")])
        #expect(try fileSize(url) == validSize)
    }

    @Test("recovery stops at the first corrupt record and truncates the rest")
    func corruptMiddleRecordStopsRecovery() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        let validSize = try fileSize(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("0000000000000000 1700000000000 {\"id\":2,\"message\":\"two\"}\n".utf8))
        try handle.close()
        // A valid record after the corrupt one is not recovered.
        try log.append(Record(id: 3, message: "three"))

        let recovered = try log.recover()
        #expect(recovered.map(\.payload) == [Record(id: 1, message: "one")])
        #expect(try fileSize(url) == validSize)
    }

    @Test("appending after recovery resumes at the end of the file")
    func appendAfterRecovery() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        _ = try log.recover()
        try log.append(Record(id: 2, message: "two"))
        #expect(try log.recover().map(\.payload) == [
            Record(id: 1, message: "one"),
            Record(id: 2, message: "two"),
        ])
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
