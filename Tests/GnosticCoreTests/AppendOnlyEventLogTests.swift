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

    @Test("byte count tracks the file and is zero when it is missing")
    func byteCountTracksFile() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        #expect(try log.byteCount() == 0)
        try log.append(Record(id: 1, message: "one"))
        #expect(try log.byteCount() == fileSize(url))
        #expect(try log.byteCount() > 0)
    }

    @Test("replaceAll rewrites the log and drops the previous records")
    func replaceAllRewritesLog() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        try log.append(Record(id: 2, message: "two"))

        try log.replaceAll(with: [Record(id: 9, message: "checkpoint")])

        #expect(try log.recover().map(\.payload) == [Record(id: 9, message: "checkpoint")])
        #expect(try log.byteCount() == fileSize(url))
    }

    @Test("replaceAll creates the log when it is missing")
    func replaceAllCreatesLog() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.replaceAll(with: [Record(id: 1, message: "one")])
        #expect(try log.recover().map(\.payload) == [Record(id: 1, message: "one")])
    }

    @Test("appending after replaceAll resumes after the replacement")
    func appendAfterReplaceAll() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        try log.replaceAll(with: [Record(id: 9, message: "checkpoint")])
        try log.append(Record(id: 10, message: "ten"))
        #expect(try log.recover().map(\.payload) == [
            Record(id: 9, message: "checkpoint"),
            Record(id: 10, message: "ten"),
        ])
    }

    @Test("a read-only scan reports a torn tail without truncating")
    func scanReportsTornTailWithoutTruncating() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        let completeSize = try fileSize(url)
        // Simulate a crash mid-write: no trailing newline and a bad checksum.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("deadbeef 1700000000000 {\"id\":2,\"message\":\"two\"}".utf8))
        try handle.close()
        let tornSize = try fileSize(url)

        let scan = try log.scan()
        #expect(scan.records.map(\.payload) == [Record(id: 1, message: "one")])
        #expect(scan.tail?.kind == .torn)
        #expect(scan.tail?.validByteCount == Int(completeSize))
        #expect(scan.tail?.totalByteCount == Int(tornSize))
        // The scan leaves the file byte-for-byte unchanged.
        #expect(try fileSize(url) == tornSize)

        // A later writer-owned recovery still truncates the tail.
        _ = try log.recover()
        #expect(try fileSize(url) == completeSize)
    }

    @Test("a read-only scan classifies damage before the end as corrupt")
    func scanReportsCorruptRecord() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        try log.append(Record(id: 1, message: "one"))
        let validSize = try fileSize(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("0000000000000000 1700000000000 {\"id\":2,\"message\":\"two\"}\n".utf8))
        try handle.close()
        // A valid record after the corrupt one makes the damage non-final.
        try log.append(Record(id: 3, message: "three"))
        let scannedSize = try fileSize(url)

        let scan = try log.scan()
        #expect(scan.records.map(\.payload) == [Record(id: 1, message: "one")])
        #expect(scan.tail?.kind == .corrupt)
        #expect(scan.tail?.validByteCount == Int(validSize))
        #expect(try fileSize(url) == scannedSize)
    }

    @Test("a scan of a missing file reports nothing and creates nothing")
    func scanMissingFile() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        let scan = try log.scan()
        #expect(scan.records.isEmpty)
        #expect(scan.tail == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("scan and recover agree on a healthy log")
    func scanMatchesRecover() throws {
        let url = makeURL()
        let log = AppendOnlyEventLog<Record>(fileURL: url)
        for index in 0..<3 {
            try log.append(Record(id: index, message: "message-\(index)"))
        }
        let scanned = try log.scan()
        let recovered = try log.recover()
        #expect(scanned.records == recovered)
        #expect(scanned.tail == nil)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
