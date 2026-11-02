// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
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

    private static func frame(_ update: String, sessionID: String = "s") -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionID)","update":\#(update)}}"#
    }

    @Test("a received frame is stored as its text and read back unchanged after a restart, in both ACP payload kinds")
    func receivedFramesSurviveRestart() async throws {
        let timelineID = UUID()
        let url = makeURL()
        let journal = try TimelineJournal(fileURL: url, timelineID: timelineID)
        let frames = [
            // Extra field, number text, duplicate keys, key order and spacing that a decoded value would change.
            Self.frame(#"{ "sessionUpdate":"state_update", "state":"running", "big":18446744073709551617, "one":1.0, "negzero":-0.0, "dup":1, "dup":2, "z":1, "a":2 }"#),
            // Deeper than Foundation can encode.
            Self.frame(
                #"{"sessionUpdate":"state_update","state":"running","deep":"#
                    + String(repeating: "[", count: 507) + String(repeating: "]", count: 507) + "}"
            ),
            // A known kind that does not fit its type, a non-object update, and no update kind.
            Self.frame(#"{"sessionUpdate":"state_update","state":5,"vendorMisfit":true}"#),
            Self.frame(#""not-an-object""#),
            Self.frame(#"{"state":"running"}"#),
            // Escapes and non-ASCII text.
            Self.frame(#"{"sessionUpdate":"vendor_text","text":"line\nbreak \u00e9 \ud83d\ude00 é 😀"}"#),
        ]
        let updates = frames.map { ReceivedACPUpdate(frame: $0) }
        #expect(updates.map(\.frame) == frames)
        #expect(updates[0].update == .stateUpdate(.running(meta: nil)))
        #expect(updates[1].update == .stateUpdate(.running(meta: nil)))
        #expect(updates[2].update == nil)
        #expect(updates[3].update == nil)
        #expect(updates[4].update == nil)
        #expect(updates[5].update?.updateKind == "vendor_text")
        for (index, update) in updates.enumerated() {
            try await journal.append(.acpUpdate(sessionID: "s", update: TurnSessionUpdate(
                timelineID: timelineID, clientTurnID: "turn", sequence: index + 1, receivedUpdate: update
            )))
            try await journal.append(.rawACPUpdate(sessionID: "s", clientTurnID: nil, update: update))
        }

        let reopened = try TimelineJournal(fileURL: url, timelineID: timelineID)
        try #require(await reopened.status() == .writable)
        var replayed: [ReceivedACPUpdate] = []
        for record in try await reopened.replay() {
            switch record.payload {
            case let .acpUpdate(_, update): replayed.append(update.receivedUpdate)
            case let .rawACPUpdate(_, _, update): replayed.append(update)
            default: break
            }
        }
        #expect(replayed == updates.flatMap { [$0, $0] })
        #expect(replayed.map(\.frame) == frames.flatMap { [$0, $0] })
    }

    @Test("the journal sets no size limit on an ACP update, whether it is stored as a frame or as a typed value")
    func largeUpdatesAreJournaledWhole() async throws {
        let text = String(repeating: "x\u{E9}\u{1F600}", count: 1_500_000)
        let framed = ReceivedACPUpdate(frame: Self.frame(#"{"sessionUpdate":"vendor_big","text":"\#(text)"}"#))
        let typed = ReceivedACPUpdate(.other(sessionUpdate: "vendor_big", fields: ["text": .string(text)]))
        let timelineID = UUID()
        let url = makeURL()
        let journal = try TimelineJournal(fileURL: url, timelineID: timelineID)
        for update in [framed, typed] {
            try await journal.append(.rawACPUpdate(sessionID: "s", clientTurnID: nil, update: update))
        }
        let reopened = try TimelineJournal(fileURL: url, timelineID: timelineID)
        try #require(await reopened.status() == .writable)
        let stored = try await reopened.replay().compactMap { record -> ReceivedACPUpdate? in
            if case let .rawACPUpdate(_, _, update) = record.payload { return update }
            return nil
        }
        #expect(stored == [framed, typed])
        #expect(framed.frame?.utf8.count ?? 0 > 10_000_000)
    }

    @Test("the journal shape of an ACP update is a string for a received frame and an object for a typed value")
    func updateShapeInTheJournal() throws {
        let text = Self.frame(#"{"sessionUpdate":"state_update","state":"running","extra":1.0}"#)
        let stored = try JSONEncoder().encode(ReceivedACPUpdate(frame: text))
        #expect(try JSONDecoder().decode(String.self, from: stored) == text)

        // A string reads as a frame. An object, which earlier journals store, reads as a typed value.
        let framed = try JSONDecoder().decode(ReceivedACPUpdate.self, from: stored)
        #expect(framed.frame == text)
        #expect(framed.update == .stateUpdate(.running(meta: nil)))
        let typed = try JSONDecoder().decode(
            ReceivedACPUpdate.self,
            from: Data(#"{"sessionUpdate":"vendor_idle","_meta":{"k":"v"}}"#.utf8)
        )
        #expect(typed.frame == nil)
        #expect(typed == ReceivedACPUpdate(.other(sessionUpdate: "vendor_idle", fields: ["_meta": .object(["k": .string("v")])])))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ReceivedACPUpdate.self, from: Data("7".utf8))
        }

        let record = #"{"formatVersion":1,"timelineID":"00000000-0000-4000-8000-000000000001","replayEpoch":"00000000-0000-4000-8000-000000000002","sequence":2,"timestamp":0,"payload":{"rawACPUpdate":{"sessionID":"s","update":"{\"jsonrpc\":\"2.0\"}"}}}"#
        let decoded = try JSONDecoder().decode(TimelineJournalRecord.self, from: Data(record.utf8))
        #expect(decoded.payload == .rawACPUpdate(
            sessionID: "s", clientTurnID: nil, update: ReceivedACPUpdate(frame: #"{"jsonrpc":"2.0"}"#)
        ))
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
        let admissionDigest = try TurnAdmissionDigest.hex(prompt: prompt, acpVersionTag: acpVersionTag)
        let update = TurnSessionUpdate(
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
