// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCore
@testable import GnosticProtocol

@Suite("Authoritative Timeline journal")
struct TimelineJournalTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("timeline.jsonl")
    }

    @Test("format version 1 reads its committed record fixture")
    func readsV1RecordFixture() throws {
        let fixture = #"{"formatVersion":1,"timelineID":"00000000-0000-4000-8000-000000000001","replayEpoch":"00000000-0000-4000-8000-000000000002","sequence":1,"timestamp":0,"payload":{"replayEpochStarted":{"previousEpoch":null,"afterSequence":0}}}"#
        let record = try JSONDecoder().decode(
            TimelineJournalRecord.self,
            from: Data(fixture.utf8)
        )
        #expect(record.formatVersion == TimelineJournalRecord.currentFormatVersion)
        #expect(record.timelineID == UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        #expect(record.replayEpoch == UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        #expect(record.sequence == 1)
        #expect(record.payload == .replayEpochStarted(previousEpoch: nil, afterSequence: 0))
    }

    @Test("records ordered host and raw ACP events across replay epochs")
    func orderedEventsAndReplayEpochs() async throws {
        let timelineID = UUID()
        let url = makeURL()
        let journal = try TimelineJournal(fileURL: url, timelineID: timelineID)
        let initial = try #require(await journal.currentCursor())
        #expect(initial.sequence == 1)

        let turnID = "turn-\(UUID().uuidString)"
        let prompt: [ACPContentBlock] = [.text(ACPTextContent(text: "prompt"))]
        let acpVersionTag = "v2"
        let admissionDigest = TimelineTurnEnvelope.computeAdmissionDigest(
            prompt: prompt,
            acpVersionTag: acpVersionTag
        )
        let update = TimelineTurnUpdate(
            timelineID: timelineID,
            clientTurnID: turnID,
            sequence: 1,
            update: .other(
                sessionUpdate: "vendor_progress",
                fields: [
                    "content": .string("working"),
                    "_meta": .object(["trace_id": .string("trace-7")]),
                ]
            )
        )
        let admission = try await journal.append(
            .turnAdmitted(
                clientTurnID: turnID,
                admissionDigest: admissionDigest,
                turnSequence: 7,
                acpVersionTag: acpVersionTag,
                prompt: prompt
            ),
            causalSpanID: UUID()
        )
        let acp = try await journal.append(
            .acpUpdate(sessionID: "session-1", update: update),
            causalSpanID: admission.causalSpanID
        )
        #expect(admission.sequence == 2)
        #expect(acp.sequence == 3)

        let firstEpoch = admission.replayEpoch
        let reopened = try TimelineJournal(fileURL: url, timelineID: timelineID)
        let reopenedRecords = try await reopened.replay()
        #expect(reopenedRecords.map(\.sequence) == [1, 2, 3, 4])
        #expect(reopenedRecords[3].replayEpoch != firstEpoch)
        #expect(reopenedRecords[3].payload == .replayEpochStarted(previousEpoch: firstEpoch, afterSequence: 3))
        #expect(reopenedRecords[2].payload == .acpUpdate(sessionID: "session-1", update: update))
        #expect(try await reopened.replay(after: TimelineReplayCursor(
            replayEpoch: acp.replayEpoch,
            sequence: acp.sequence
        )).map(\.sequence) == [4])
    }

    @Test("a replay cursor with the wrong epoch is rejected")
    func rejectsDivergentReplayCursor() async throws {
        let journal = try TimelineJournal(fileURL: makeURL(), timelineID: UUID())
        let cursor = try #require(await journal.currentCursor())
        var divergence: TimelineJournalError?
        do {
            _ = try await journal.replay(after: TimelineReplayCursor(
                replayEpoch: UUID(),
                sequence: cursor.sequence
            ))
        } catch let error as TimelineJournalError {
            divergence = error
        }
        guard let divergence else {
            Issue.record("Expected a replay epoch divergence error")
            return
        }
        if case let .replayEpochDivergence(expected, actual) = divergence {
            #expect(expected != actual)
        } else {
            Issue.record("Expected a replay epoch divergence error, got \(divergence)")
        }
    }

    @Test("opening truncates an incomplete final frame and starts a new epoch")
    func truncatesOnlyTornTail() async throws {
        let timelineID = UUID()
        let url = makeURL()
        let journal = try TimelineJournal(fileURL: url, timelineID: timelineID)
        let created = try await journal.append(.timelineCreated(
            title: "work",
            runtimeInstanceID: UUID(),
            attachments: []
        ))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("partial-frame-without-newline".utf8))
        try handle.close()

        let recovered = try TimelineJournal(fileURL: url, timelineID: timelineID)
        let records = try await recovered.replay()
        #expect(records.map(\.sequence) == [1, 2, 3])
        #expect(records[1] == created)
        #expect(records[2].payload == .replayEpochStarted(
            previousEpoch: created.replayEpoch,
            afterSequence: created.sequence
        ))
    }

    @Test("complete checksum corruption quarantines the Timeline without truncating")
    func quarantinesCommittedCorruption() async throws {
        let timelineID = UUID()
        let url = makeURL()
        let journal = try TimelineJournal(fileURL: url, timelineID: timelineID)
        _ = try await journal.append(.timelineCreated(
            title: "work",
            runtimeInstanceID: UUID(),
            attachments: []
        ))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("0000000000000000 1700000000000 {\"invalid\":true}\n".utf8))
        try handle.close()
        let corruptSize = try fileSize(url)

        let reopened = try TimelineJournal(fileURL: url, timelineID: timelineID)
        guard case let .quarantined(diagnostic) = await reopened.status() else {
            Issue.record("Expected the committed corrupt record to quarantine the Timeline")
            return
        }
        #expect(diagnostic.timelineID == timelineID)
        #expect(diagnostic.validThroughSequence == 2)
        #expect(!diagnostic.reason.isEmpty)
        #expect(try fileSize(url) == corruptSize)

        var appendFailed = false
        do {
            _ = try await reopened.append(.timelineRenamed(title: "must-not-commit"))
        } catch {
            appendFailed = true
        }
        #expect(appendFailed)
        #expect(try fileSize(url) == corruptSize)
    }

    @Test("unknown storage versions are rejected instead of reinterpreted")
    func rejectsUnknownFormatVersion() throws {
        let timelineID = UUID()
        let url = makeURL()
        let record = TimelineJournalRecord(
            formatVersion: TimelineJournalRecord.currentFormatVersion + 1,
            timelineID: timelineID,
            replayEpoch: UUID(),
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            causalSpanID: nil,
            payload: .replayEpochStarted(previousEpoch: nil, afterSequence: 0)
        )
        try AppendOnlyEventLog<TimelineJournalRecord>(fileURL: url).append(record)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("uncommitted-suffix".utf8))
        try handle.close()
        let original = try Data(contentsOf: url)

        var rejection: TimelineJournalError?
        do {
            _ = try TimelineJournal(fileURL: url, timelineID: timelineID)
        } catch let error as TimelineJournalError {
            rejection = error
        }
        #expect(rejection == .unsupportedFormatVersion(
            actual: TimelineJournalRecord.currentFormatVersion + 1,
            supported: TimelineJournalRecord.currentFormatVersion
        ))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("semantic corruption with a torn suffix preserves the entire source")
    func corruptPrefixPreservesTornSuffix() async throws {
        let timelineID = UUID()
        let url = makeURL()
        let log = AppendOnlyEventLog<TimelineJournalRecord>(fileURL: url)
        try log.append(TimelineJournalRecord(
            timelineID: timelineID, replayEpoch: UUID(), sequence: 7, timestamp: Date(), causalSpanID: nil,
            payload: .replayEpochStarted(previousEpoch: nil, afterSequence: 0)
        ))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("partial".utf8))
        try handle.close()
        let original = try Data(contentsOf: url)
        let journal = try TimelineJournal(fileURL: url, timelineID: timelineID)
        guard case .quarantined = await journal.status() else {
            Issue.record("Expected corrupt committed sequence to quarantine the journal")
            return
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("a Turn admission digest must match its stored prompt blocks")
    func rejectsAdmissionDigestMismatch() async throws {
        let url = makeURL()
        let journal = try TimelineJournal(fileURL: url, timelineID: UUID())
        var rejection: TimelineJournalError?
        do {
            _ = try await journal.append(.turnAdmitted(
                clientTurnID: "digest-mismatch",
                admissionDigest: "wrong-digest",
                turnSequence: 1,
                acpVersionTag: "v2",
                prompt: [.text(ACPTextContent(text: "prompt"))]
            ))
        } catch let error as TimelineJournalError {
            rejection = error
        }
        guard case .invalidPayload? = rejection else {
            Issue.record("Expected a mismatched prompt digest to be rejected")
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.size] as? NSNumber != nil)
        #expect(try await journal.replay().count == 1)
    }

    @Test("the store shares one journal writer per Timeline")
    func storeSharesJournalWriter() async throws {
        let store = TimelineJournalStore(directoryURL: makeURL().deletingLastPathComponent())
        let timelineID = UUID()
        let first = try await store.journal(for: timelineID)
        let second = try await store.journal(for: timelineID)
        #expect(first === second)
        #expect(try await store.timelineIDs() == [timelineID])
    }

    @Test("the store rejects a Timeline journal file with an unknown filename version")
    func rejectsUnknownJournalFilenameVersion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-journal-unknown-filename-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timelineID = UUID()
        let name = "timeline-\(timelineID.uuidString.lowercased())-v2.jsonl"
        try Data().write(to: directory.appendingPathComponent(name))
        let store = TimelineJournalStore(directoryURL: directory)

        var rejection: TimelineJournalError?
        do {
            _ = try await store.timelineIDs()
        } catch let error as TimelineJournalError {
            rejection = error
        }
        #expect(rejection == .invalidJournalFileName(name))
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
