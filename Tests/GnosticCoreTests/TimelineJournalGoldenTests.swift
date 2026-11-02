// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
import Testing
@testable import GnosticCore
@testable import GnosticProtocol

/// Pins the version 1 on-disk Timeline journal format
/// (`Documentation/Architecture/Timeline-Journal-Format.md`) to committed bytes.
///
/// `Tests/Fixtures/TimelineJournal/timeline-v1.golden.jsonl` holds thirteen
/// frames, one for each payload kind and a second replay epoch. Its checksums
/// are FNV-1a 64-bit values that a script computed independently of the
/// implementation, and its admission digest was cross-checked against
/// `hashlib.sha256` over the RFC 8785 form of the admission document. A change
/// to the frame, the checksum, a payload's JSON shape, or the digest breaks
/// these tests even when the writer and reader still agree with each other.
@Suite("Timeline journal golden format")
struct TimelineJournalGoldenTests {
    private static let timelineID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let firstEpoch = UUID(uuidString: "00000000-0000-4000-8000-0000000000e1")!
    private static let secondEpoch = UUID(uuidString: "00000000-0000-4000-8000-0000000000e2")!
    private static let goldenRecordCount = 13

    private static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TimelineJournal/timeline-v1.golden.jsonl")
    }

    private func golden() throws -> Data { try Data(contentsOf: Self.goldenURL) }

    /// A scratch journal path with the golden bytes, or other bytes, in place.
    private func install(_ bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-journal-golden-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = TimelineJournalStore.fileURL(for: Self.timelineID, in: directory)
        try bytes.write(to: url)
        return url
    }

    /// The reference FNV-1a 64-bit checksum, written out here so the test does
    /// not depend on the implementation's own function.
    private static func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private func frames(_ data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// Checks the documented layout of every frame in `data`: a 16-digit
    /// lowercase checksum, a millisecond time, a JSON object, and a commit
    /// newline. Returns the number of frames.
    @discardableResult
    private func verifyFrames(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        #expect(data.last == 0x0A, "The last frame must end with the commit newline.", sourceLocation: sourceLocation)
        let lines = frames(data)
        for (index, line) in lines.enumerated() {
            let firstSpace = try #require(line.firstIndex(of: 0x20), sourceLocation: sourceLocation)
            let checksumText = String(decoding: line[line.startIndex..<firstSpace], as: UTF8.self)
            #expect(
                checksumText.count == 16 && checksumText == checksumText.lowercased(),
                "frame \(index + 1)",
                sourceLocation: sourceLocation
            )
            let body = line[line.index(after: firstSpace)...]
            #expect(
                UInt64(checksumText, radix: 16) == Self.fnv1a(body),
                "frame \(index + 1) checksum",
                sourceLocation: sourceLocation
            )
            let secondSpace = try #require(body.firstIndex(of: 0x20), sourceLocation: sourceLocation)
            #expect(
                Int64(String(decoding: body[body.startIndex..<secondSpace], as: UTF8.self)) != nil,
                sourceLocation: sourceLocation
            )
            #expect(body[body.index(after: secondSpace)] == UInt8(ascii: "{"), sourceLocation: sourceLocation)
        }
        return lines.count
    }

    @Test("the committed frames follow the documented layout and checksum")
    func goldenFramesMatchTheDocumentedLayout() throws {
        #expect(try verifyFrames(try golden()) == Self.goldenRecordCount)
    }

    @Test("a journal written as the format reference describes opens, replays every payload, and starts a new epoch")
    func goldenJournalReplays() async throws {
        let golden = try golden()
        let url = try install(golden)
        let journal = try TimelineJournal(fileURL: url, timelineID: Self.timelineID)

        try #require(await journal.status() == .writable, "The golden journal did not open as writable.")
        let records = try await journal.replay()
        try #require(
            records.map(\.sequence) == Array(1...UInt64(Self.goldenRecordCount + 1)),
            "The golden journal did not replay all its records."
        )
        #expect(records.allSatisfy { $0.formatVersion == 1 && $0.timelineID == Self.timelineID })
        #expect(records.prefix(12).allSatisfy { $0.replayEpoch == Self.firstEpoch })

        let workspace = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
        let runtime = UUID(uuidString: "00000000-0000-4000-8000-0000000000b1")!
        let prompt: [ACPContentBlock] = [.text(ACPTextContent(text: "hello"))]
        let payloads = records.map(\.payload)
        #expect(payloads[0] == .replayEpochStarted(previousEpoch: nil, afterSequence: 0))
        #expect(payloads[1] == .timelineCreated(title: "Golden", runtimeInstanceID: runtime, attachments: [
            TimelineJournalWorkspaceAttachment(workspaceID: workspace, uri: nil, scope: .local),
            TimelineJournalWorkspaceAttachment(
                workspaceID: UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!,
                uri: "workspace://remote",
                scope: .network
            ),
        ]))
        #expect(payloads[2] == .timelineRenamed(title: "Renamed"))
        #expect(payloads[3] == .projectChanged(project: .local("/srv/golden")))
        #expect(payloads[4] == .workspaceAttached(workspaceID: workspace, uri: "workspace://local", scope: .local))
        #expect(payloads[5] == .workspaceDetached(workspaceID: workspace))
        #expect(payloads[6] == .sessionTransition(
            sessionID: "session-golden", runtimeInstanceID: runtime, state: .live, projectKind: .local, cwd: "/srv/golden"
        ))
        #expect(payloads[7] == .turnAdmitted(
            clientTurnID: "golden-turn",
            admissionDigest: "f644f2f95d171759579198c410c35ce264adf9dbf1a96832674b2257b0149128",
            turnSequence: 1,
            acpVersionTag: "acp-v2@39ae6a2",
            prompt: prompt
        ))
        #expect(payloads[8] == .acpUpdate(sessionID: "session-golden", update: TurnSessionUpdate(
            timelineID: Self.timelineID,
            clientTurnID: "golden-turn",
            sequence: 1,
            update: .other(sessionUpdate: "vendor_progress", fields: [
                "content": .string("working"),
                "_meta": .object(["trace_id": .string("trace-7")]),
            ])
        )))
        #expect(payloads[9] == .rawACPUpdate(
            sessionID: "session-golden",
            clientTurnID: nil,
            update: .other(sessionUpdate: "vendor_idle", fields: ["_meta": .object(["k": .string("v")])])
        ))
        #expect(payloads[10] == .permissionDecision(
            correlationID: "perm-1", clientTurnID: "golden-turn", decision: "unavailable", approved: false
        ))
        #expect(payloads[11] == .turnCompleted(clientTurnID: "golden-turn", outcome: .completed, messageID: "msg-1"))
        #expect(payloads[12] == .replayEpochStarted(previousEpoch: Self.firstEpoch, afterSequence: 12))
        #expect(records[11].causalSpanID == UUID(uuidString: "00000000-0000-4000-8000-0000000000c1"))
        #expect(records[12].replayEpoch == Self.secondEpoch)

        // Opening continues the log with a fresh epoch that names the last one.
        #expect(records[13].replayEpoch != Self.secondEpoch)
        #expect(records[13].payload == .replayEpochStarted(previousEpoch: Self.secondEpoch, afterSequence: 13))
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk.prefix(golden.count) == golden, "Opening rewrote committed frames.")
        #expect(try verifyFrames(onDisk) == Self.goldenRecordCount + 1)

        let projection = try #require(await journal.timelineProjection())
        #expect(projection.title == "Renamed")
        #expect(projection.runtimeInstanceID == runtime)
        #expect(projection.attachments.map(\.scope) == [.network])
        #expect(projection.project == .local("/srv/golden"))
        #expect(projection.latestSession?.sessionID == "session-golden")
        #expect(projection.latestSession?.state == .live)
    }

    @Test("every committed record re-encodes to the committed JSON, so the writer's payload shapes cannot drift")
    func goldenRecordsRoundTripByteForByte() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (index, line) in frames(try golden()).enumerated() {
            let firstSpace = try #require(line.firstIndex(of: 0x20))
            let afterChecksum = line[line.index(after: firstSpace)...]
            let secondSpace = try #require(afterChecksum.firstIndex(of: 0x20))
            let json = Data(afterChecksum[afterChecksum.index(after: secondSpace)...])
            let record = try JSONDecoder().decode(TimelineJournalRecord.self, from: json)
            #expect(try encoder.encode(record) == json, "record \(index + 1) changed shape")
        }
    }

    @Test("the writer commits a documented frame: lowercase checksum, millisecond time, JSON, newline")
    func writerEmitsTheDocumentedFrame() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-journal-golden-writer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = TimelineJournalStore(directoryURL: directory)
        let timelineID = UUID()
        let journal = try await store.journal(for: timelineID)
        try await journal.append(.timelineRenamed(title: "frame"))

        let url = TimelineJournalStore.fileURL(for: timelineID, in: directory)
        #expect(url.lastPathComponent == "timeline-\(timelineID.uuidString.lowercased())-v1.jsonl")
        let data = try Data(contentsOf: url)
        #expect(try verifyFrames(data) == 2)
        for line in frames(data) {
            let firstSpace = try #require(line.firstIndex(of: 0x20))
            let body = line[line.index(after: firstSpace)...]
            let secondSpace = try #require(body.firstIndex(of: 0x20))
            #expect(Int64(String(decoding: body[body.startIndex..<secondSpace], as: UTF8.self)) ?? 0 > 1_700_000_000_000)
            let json = try #require(
                try JSONSerialization.jsonObject(with: Data(body[body.index(after: secondSpace)...])) as? [String: Any]
            )
            #expect(json["formatVersion"] as? Int == 1)
            #expect(json["timelineID"] as? String == timelineID.uuidString)
        }

        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test("an incomplete final frame is truncated to the last committed byte and nothing else changes")
    func tornTailTruncatesExactly() async throws {
        let golden = try golden()
        let lines = frames(golden)
        // A crash inside the last frame, before its commit newline.
        let torn = Data(lines[lines.count - 1].prefix(40))
        let url = try install(golden.dropLast(lines[lines.count - 1].count + 1) + torn)
        let committed = golden.dropLast(lines[lines.count - 1].count + 1)

        let journal = try TimelineJournal(fileURL: url, timelineID: Self.timelineID)

        try #require(await journal.status() == .writable, "Recovery of a torn tail quarantined the journal.")
        let records = try await journal.replay()
        try #require(records.map(\.sequence) == Array(1...UInt64(Self.goldenRecordCount)), "Recovery lost committed records.")
        // The torn epoch marker is gone; the epoch that replaced it follows record 12.
        #expect(records[12].payload == .replayEpochStarted(previousEpoch: Self.firstEpoch, afterSequence: 12))
        #expect(records[12].replayEpoch != Self.secondEpoch)
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk.prefix(committed.count) == committed, "Recovery changed bytes before the torn tail.")
        // Every remaining byte belongs to a checksummed frame: truncation removed
        // the torn bytes instead of leaving them in front of the new epoch frame.
        #expect(try verifyFrames(onDisk) == Self.goldenRecordCount)
        #expect(!onDisk.dropFirst(committed.count).starts(with: torn))
    }

    @Test("a damaged committed frame quarantines the journal at the last valid sequence and leaves every byte alone")
    func damagedFrameQuarantines() async throws {
        var damaged = try golden()
        let marker = Data("Renamed".utf8)
        let range = try #require(damaged.range(of: marker))
        damaged.replaceSubrange(range, with: Data("Rexamed".utf8))
        let url = try install(damaged)

        let journal = try TimelineJournal(fileURL: url, timelineID: Self.timelineID)

        guard case let .quarantined(diagnostic) = await journal.status() else {
            Issue.record("A checksum failure in a committed frame did not quarantine the journal.")
            return
        }
        #expect(diagnostic.validThroughSequence == 2)
        #expect(try await journal.replay().map(\.sequence) == [1, 2])
        await #expect(throws: TimelineJournalError.self) {
            try await journal.append(.timelineRenamed(title: "must not commit"))
        }
        #expect(try Data(contentsOf: url) == damaged, "Quarantine modified the journal.")
    }

    @Test("a journal from a later format version is refused and left unchanged")
    func laterFormatVersionIsRefused() throws {
        let golden = try golden()
        let lines = frames(golden)
        // Rewrite frame 1 as format version 2 with a checksum that is valid for its new bytes.
        let first = lines[0]
        let firstSpace = try #require(first.firstIndex(of: 0x20))
        let secondSpace = try #require(first[first.index(after: firstSpace)...].firstIndex(of: 0x20))
        let time = String(decoding: first[first.index(after: firstSpace)..<secondSpace], as: UTF8.self)
        let json = String(decoding: first[first.index(after: secondSpace)...], as: UTF8.self)
            .replacingOccurrences(of: #""formatVersion":1"#, with: #""formatVersion":2"#)
        let body = Data("\(time) \(json)".utf8)
        let checksum = String(Self.fnv1a(body), radix: 16)
        var bytes = Data(String(repeating: "0", count: 16 - checksum.count).utf8 + Data(checksum.utf8))
        bytes.append(0x20)
        bytes.append(body)
        bytes.append(0x0A)
        let url = try install(bytes)

        #expect(throws: TimelineJournalError.unsupportedFormatVersion(actual: 2, supported: 1)) {
            _ = try TimelineJournal(fileURL: url, timelineID: Self.timelineID)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
