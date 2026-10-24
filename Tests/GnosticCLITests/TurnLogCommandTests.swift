// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

@Suite("Turn log command")
struct TurnLogCommandTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-log-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLog(in folder: URL) -> (AppendOnlyEventLog<TurnEventRecord>, URL) {
        let url = folder.appendingPathComponent("turn-events-v1.jsonl")
        return (AppendOnlyEventLog<TurnEventRecord>(fileURL: url), url)
    }

    @discardableResult
    private func appendTornFragment(to url: URL) throws -> UInt64 {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("deadbeef 1700000000000 {".utf8))
        try handle.close()
        return try fileSize(url)
    }

    @Test("an explicit --turn-log is used verbatim")
    func explicitPathWins() throws {
        let command = try TurnLogCommand.parse(["--turn-log", "/var/lib/gnostic/custom/turns.jsonl"])
        #expect(command.turnLogPath == "/var/lib/gnostic/custom/turns.jsonl")
        let location = TurnLogLocation(turnLogPath: command.turnLogPath)
        #expect(location.turnLogURL(environment: [:])?.path == "/var/lib/gnostic/custom/turns.jsonl")
    }

    @Test("GNOSTIC_STATE_HOME derives the log path")
    func stateHomeDerivesPath() {
        let location = TurnLogLocation(turnLogPath: nil)
        #expect(
            location.turnLogURL(environment: ["GNOSTIC_STATE_HOME": "/srv/gnostic"])?.path
                == "/srv/gnostic/turn-events-v1.jsonl"
        )
    }

    @Test("an unset state directory yields no location")
    func noConfiguration() {
        #expect(TurnLogLocation(turnLogPath: nil).turnLogURL(environment: [:]) == nil)
    }

    @Test("a missing log reports no turns and no tail")
    func missingLog() throws {
        let (log, url) = makeLog(in: try makeFolder())
        let report = TurnLogReport(scan: try log.scan(), path: url.path, exists: false)
        #expect(report.recordCount == 0)
        #expect(report.turnCount == 0)
        #expect(report.checksumsValid)
        #expect(report.tail == nil)
        #expect(report.turns.isEmpty)
        #expect(report.humanDescription().contains("file does not exist"))
    }

    @Test("records are grouped into one turn with lifecycle counts")
    func groupsOneTurn() throws {
        let (log, url) = makeLog(in: try makeFolder())
        let timelineID = UUID()
        try log.append(TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .started(messageDigest: 42)))
        try log.append(TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .update(
            AscendantTurnUpdate(sequence: 1, kind: "assistant_text", text: "hi")
        )))
        try log.append(TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .update(
            AscendantTurnUpdate(sequence: 2, kind: "done", terminal: true)
        )))
        try log.append(TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .finished))

        let report = TurnLogReport(scan: try log.scan(), path: url.path, exists: true)
        #expect(report.recordCount == 4)
        #expect(report.turnCount == 1)
        let turn = try #require(report.turns.first)
        #expect(turn.timelineID == timelineID.uuidString.lowercased())
        #expect(turn.clientTurnID == "turn-1")
        #expect(turn.events == 4)
        #expect(turn.updates == 2)
        #expect(turn.finished)
        #expect(turn.messageDigest == 42)
        #expect(turn.lastSequence == 2)
        #expect(turn.terminal == true)
        #expect(turn.startedAt != nil)
        #expect(turn.lastRecordedAt != nil)
    }

    @Test("distinct turns are listed separately in first-seen order")
    func separatesTurns() throws {
        let (log, url) = makeLog(in: try makeFolder())
        let first = UUID()
        let second = UUID()
        try log.append(TurnEventRecord(timelineID: first, clientTurnID: "a", event: .started(messageDigest: nil)))
        try log.append(TurnEventRecord(timelineID: second, clientTurnID: "b", event: .started(messageDigest: nil)))
        let report = TurnLogReport(scan: try log.scan(), path: url.path, exists: true)
        #expect(report.turnCount == 2)
        #expect(report.turns.map(\.clientTurnID) == ["a", "b"])
    }

    @Test("a compaction checkpoint is summarized as one compacted turn")
    func checkpointRecordIsSummarized() throws {
        let (log, url) = makeLog(in: try makeFolder())
        let timelineID = UUID()
        try log.append(TurnEventRecord(timelineID: timelineID, clientTurnID: "turn-1", event: .checkpoint(
            TurnJournalCheckpoint(
                messageDigest: 9,
                nextSequence: 3,
                updates: [
                    AscendantTurnUpdate(sequence: 1, kind: "assistant_text", text: "hi"),
                    AscendantTurnUpdate(sequence: 2, kind: "done", terminal: true),
                ],
                compacted: true,
                terminal: true,
                finished: true
            )
        )))
        let report = TurnLogReport(scan: try log.scan(), path: url.path, exists: true)
        #expect(report.recordCount == 1)
        #expect(report.turnCount == 1)
        let turn = try #require(report.turns.first)
        #expect(turn.compacted)
        #expect(turn.events == 1)
        #expect(turn.updates == 2)
        #expect(turn.finished)
        #expect(turn.messageDigest == 9)
        #expect(turn.lastSequence == 2)
        #expect(turn.terminal == true)
        #expect(report.humanDescription().contains("compacted"))
    }

    @Test("a torn tail is reported and the file is left unchanged")
    func tornTailReported() throws {
        let (log, url) = makeLog(in: try makeFolder())
        try log.append(TurnEventRecord(timelineID: UUID(), clientTurnID: "turn-1", event: .started(messageDigest: 7)))
        let tornSize = try appendTornFragment(to: url)

        let report = TurnLogReport(scan: try log.scan(), path: url.path, exists: true)
        #expect(report.recordCount == 1)
        #expect(!report.checksumsValid)
        #expect(report.tail?.kind == "torn")
        #expect(report.tail?.validBytes ?? 0 < report.tail?.totalBytes ?? 0)
        #expect(report.humanDescription().contains("torn tail"))
        // The read-only command does not truncate the tail.
        #expect(try fileSize(url) == tornSize)
    }

    @Test("a torn tail exits with code 2")
    func tornTailExitsWithTwo() async throws {
        let (log, url) = makeLog(in: try makeFolder())
        try log.append(TurnEventRecord(timelineID: UUID(), clientTurnID: "turn-1", event: .started(messageDigest: nil)))
        try appendTornFragment(to: url)

        let command = try TurnLogCommand.parse(["--turn-log", url.path])
        do {
            try await command.run()
            Issue.record("turn-log should exit nonzero for a torn tail")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == 2)
        }
    }

    @Test("a clean log exits successfully")
    func cleanLogExitsZero() async throws {
        let (log, url) = makeLog(in: try makeFolder())
        try log.append(TurnEventRecord(timelineID: UUID(), clientTurnID: "turn-1", event: .started(messageDigest: nil)))

        let command = try TurnLogCommand.parse(["--turn-log", url.path])
        try await command.run()
    }

    @Test("JSON output carries the stable report keys")
    func jsonShape() throws {
        let (log, url) = makeLog(in: try makeFolder())
        try log.append(TurnEventRecord(timelineID: UUID(), clientTurnID: "turn-1", event: .started(messageDigest: 5)))
        let report = TurnLogReport(scan: try log.scan(), path: url.path, exists: true)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(JSONOutput.encode(report).utf8)) as? [String: Any]
        )
        #expect(object["path"] as? String == url.path)
        #expect(object["recordCount"] as? Int == 1)
        #expect(object["turnCount"] as? Int == 1)
        #expect(object["checksumsValid"] as? Bool == true)
        #expect(object["tail"] == nil)
        let turns = try #require(object["turns"] as? [[String: Any]])
        #expect(turns.first?["clientTurnID"] as? String == "turn-1")
        #expect((turns.first?["messageDigest"] as? NSNumber)?.uint64Value == 5)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
