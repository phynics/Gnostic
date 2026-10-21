// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKTestSupport
import PositronicKit
import Testing
@testable import GnosticPositronicBackend

@testable import GnosticCore

/// Durable repository behavior for the file-backed ``TimelineRuntimeRepository`` (#531).
///
/// The shared conformance suite proves the transition semantics match the reference
/// implementation; the focused suites prove the durability guarantee itself: state
/// survives a restart, a torn tail costs at most the final record, and pruning is
/// deterministic across replay.
@Suite("File-backed Timeline runtime repository")
struct FileTimelineRuntimeRepositoryTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("file-timeline-runtime-repository-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("timeline.jsonl")
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    /// Compares a Turn across a restart without its audit-entry identifiers.
    ///
    /// The reference implementation mints `TurnNotice` and cascade `TurnQuarantine`
    /// identifiers internally, so replay regenerates them. Every caller-visible field the
    /// runtime exposes (lifecycle, rounds, outcome, correlations, tool records, terminal
    /// handle) is still compared byte for byte.
    private func turnSignature(_ turn: TurnRecord) throws -> String {
        let data = try canonicalJSON(turn)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self)
        }
        if let notices = object["notices"] as? [[String: Any]] {
            object["notices"] = notices.map { notice in
                var copy = notice
                copy.removeValue(forKey: "id")
                return copy
            }
        }
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: normalized, as: UTF8.self)
    }

    private func makeTurnFixture() -> (
        timelineID: UUID,
        requestID: UUID,
        turnID: UUID,
        workspaceID: UUID,
        input: TimelineMessage,
        toolMessage: TimelineMessage,
        final: TimelineMessage
    ) {
        let timelineID = UUID()
        let requestID = UUID()
        let turnID = UUID()
        return (
            timelineID,
            requestID,
            turnID,
            UUID(),
            TimelineMessage(id: UUID(), timelineID: timelineID, role: .user, content: "hello", timestamp: date(0)),
            TimelineMessage(id: UUID(), timelineID: timelineID, role: .tool, content: "tool output", timestamp: date(2), toolCallID: "call-1"),
            TimelineMessage(id: UUID(), timelineID: timelineID, role: .assistant, content: "done", timestamp: date(4))
        )
    }

    @Test("is durable")
    func isDurable() async throws {
        let repository = try await FileTimelineRuntimeRepository(fileURL: makeURL())
        #expect(repository.isDurable)
    }

    @Test("passes the shared TimelineRuntimeRepository conformance suite")
    func conformance() async throws {
        let directory = makeURL().deletingLastPathComponent()
        try await TimelineRuntimeRepositoryConformanceSuite.run(summaryStorage: .required) {
            try await FileTimelineRuntimeRepository(
                fileURL: directory.appendingPathComponent("\(UUID().uuidString).jsonl")
            )
        }
    }

    @Test("every mutation survives a restart")
    func restartRoundTrip() async throws {
        let url = makeURL()
        let fixture = makeTurnFixture()

        let first = try await FileTimelineRuntimeRepository(fileURL: url)
        try await first.saveTimeline(TimelineRecord(id: fixture.timelineID, title: "Durable", attachedAgentID: nil))
        let admission = try await first.admitTurn(
            timelineID: fixture.timelineID,
            requestID: fixture.requestID,
            callerIntentFingerprint: "message:hello",
            inputMessage: fixture.input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: fixture.turnID,
            now: date(0)
        )
        #expect(admission.disposition == .admitted)
        try await first.beginModelRound(turnID: fixture.turnID, modelRoundIndex: 1, now: date(1))
        try await first.appendCorrelation(
            turnID: fixture.turnID,
            correlation: TurnCorrelation(id: UUID(), kind: "provider", value: "corr-1"),
            now: date(1)
        )
        let intent = RuntimeToolIntent(
            id: UUID(),
            turnID: fixture.turnID,
            timelineID: fixture.timelineID,
            toolCallID: "call-1",
            name: "echo",
            arguments: "{}",
            modelRoundIndex: 1,
            createdAt: date(1)
        )
        try await first.recordToolIntent(intent)
        let result = RuntimeToolResult(
            id: UUID(),
            turnID: fixture.turnID,
            timelineID: fixture.timelineID,
            toolCallID: "call-1",
            output: "tool output",
            createdAt: date(2)
        )
        try await first.recordToolResult(result, message: fixture.toolMessage)
        try await first.beginModelRound(turnID: fixture.turnID, modelRoundIndex: 2, now: date(3))
        _ = try await first.completeTurn(
            turnID: fixture.turnID,
            outcome: .completed,
            finalMessage: fixture.final,
            terminalHandle: TurnTerminalHandle(id: UUID(), turnID: fixture.turnID),
            now: date(4)
        )
        try await first.saveSummary(
            TimelineSummary(
                id: UUID(),
                timelineID: fixture.timelineID,
                sourceMessageIDs: [fixture.input.id, fixture.final.id],
                text: "summary",
                createdAt: date(5),
                updatedAt: date(5)
            )
        )
        _ = try await first.claim(workspaceID: fixture.workspaceID, for: fixture.timelineID, now: date(5))

        // A fresh repository over the same file must reproduce the exact state.
        let second = try await FileTimelineRuntimeRepository(fileURL: url)
        let firstTimelines = try canonicalJSON(await first.fetchAllTimelines(includeArchived: true))
        let secondTimelines = try canonicalJSON(await second.fetchAllTimelines(includeArchived: true))
        #expect(firstTimelines == secondTimelines)
        let firstMessages = try canonicalJSON(await first.fetchMessages(for: fixture.timelineID))
        let secondMessages = try canonicalJSON(await second.fetchMessages(for: fixture.timelineID))
        #expect(firstMessages == secondMessages)
        let firstTurn = try #require(try await first.fetchTurn(id: fixture.turnID))
        let secondTurn = try #require(try await second.fetchTurn(id: fixture.turnID))
        let firstTurnSignature = try turnSignature(firstTurn)
        let secondTurnSignature = try turnSignature(secondTurn)
        #expect(firstTurnSignature == secondTurnSignature, "first=\(firstTurnSignature) second=\(secondTurnSignature)")
        let firstIntents = try canonicalJSON(await first.fetchToolIntents(turnID: fixture.turnID))
        let secondIntents = try canonicalJSON(await second.fetchToolIntents(turnID: fixture.turnID))
        #expect(firstIntents == secondIntents)
        let firstResults = try canonicalJSON(await first.fetchToolResults(turnID: fixture.turnID))
        let secondResults = try canonicalJSON(await second.fetchToolResults(turnID: fixture.turnID))
        #expect(firstResults == secondResults)
        let firstSummaries = try canonicalJSON(await first.fetchSummaries(for: fixture.timelineID))
        let secondSummaries = try canonicalJSON(await second.fetchSummaries(for: fixture.timelineID))
        #expect(firstSummaries == secondSummaries)
        let firstBindings = try canonicalJSON(await first.bindings(for: fixture.timelineID))
        let secondBindings = try canonicalJSON(await second.bindings(for: fixture.timelineID))
        #expect(firstBindings == secondBindings)
        #expect(second.isDurable)
    }

    @Test("a torn tail costs at most the final mutation")
    func tornTail() async throws {
        let url = makeURL()
        let fixture = makeTurnFixture()
        let first = try await FileTimelineRuntimeRepository(fileURL: url)
        try await first.saveTimeline(TimelineRecord(id: fixture.timelineID))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("deadbeef 123 not-json\n".utf8))
        try handle.close()

        let second = try await FileTimelineRuntimeRepository(fileURL: url)
        #expect(try await second.fetchTimeline(id: fixture.timelineID) != nil)
    }

    @Test("deleting a timeline cascades across replay")
    func cascadeDeleteSurvivesRestart() async throws {
        let url = makeURL()
        let fixture = makeTurnFixture()
        let first = try await FileTimelineRuntimeRepository(fileURL: url)
        try await first.saveTimeline(TimelineRecord(id: fixture.timelineID))
        _ = try await first.admitTurn(
            timelineID: fixture.timelineID,
            requestID: fixture.requestID,
            callerIntentFingerprint: "message:hello",
            inputMessage: fixture.input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: fixture.turnID,
            now: date(0)
        )
        try await first.deleteTimeline(id: fixture.timelineID)

        let second = try await FileTimelineRuntimeRepository(fileURL: url)
        #expect(try await second.fetchTimeline(id: fixture.timelineID) == nil)
        #expect(try await second.fetchMessages(for: fixture.timelineID).isEmpty)
    }

    @Test("pruning deletes the same timelines across replay")
    func pruneIsDeterministic() async throws {
        let url = makeURL()
        let stale = TimelineRecord(id: UUID(), title: "stale", createdAt: date(0), updatedAt: date(0))
        let fresh = TimelineRecord(id: UUID(), title: "fresh", createdAt: date(0), updatedAt: Date())
        let first = try await FileTimelineRuntimeRepository(fileURL: url)
        try await first.saveTimeline(stale)
        try await first.saveTimeline(fresh)
        let preview = try await first.pruneTimelines(olderThan: 3_600, excluding: [], dryRun: true)
        #expect(preview == 1)
        #expect(try await first.fetchTimeline(id: stale.id) != nil)
        let deleted = try await first.pruneTimelines(olderThan: 3_600, excluding: [], dryRun: false)
        #expect(deleted == 1)

        let second = try await FileTimelineRuntimeRepository(fileURL: url)
        #expect(try await second.fetchTimeline(id: stale.id) == nil)
        #expect(try await second.fetchTimeline(id: fresh.id) != nil)
    }

    @Test("workspace bindings survive a restart")
    func workspaceBindingRoundTrip() async throws {
        let url = makeURL()
        let workspaceID = UUID()
        let timelineID = UUID()
        let first = try await FileTimelineRuntimeRepository(fileURL: url)
        try await first.saveTimeline(TimelineRecord(id: timelineID))
        _ = try await first.claim(workspaceID: workspaceID, for: timelineID, now: date(0))

        let second = try await FileTimelineRuntimeRepository(fileURL: url)
        #expect(try await second.timelineID(for: workspaceID) == timelineID)
    }

    @Test("a quarantined turn survives a restart")
    func quarantineSurvivesRestart() async throws {
        let url = makeURL()
        let fixture = makeTurnFixture()
        let first = try await FileTimelineRuntimeRepository(fileURL: url)
        try await first.saveTimeline(TimelineRecord(id: fixture.timelineID))
        _ = try await first.admitTurn(
            timelineID: fixture.timelineID,
            requestID: fixture.requestID,
            callerIntentFingerprint: "message:hello",
            inputMessage: fixture.input,
            executionKind: .direct,
            capturedAgentID: nil,
            turnID: fixture.turnID,
            now: date(0)
        )
        let result = try await first.interruptTurn(
            turnID: fixture.turnID,
            reason: "abandoned",
            disposition: .quarantined("side effect unresolved"),
            now: date(1)
        )
        #expect(result.record.isQuarantined)

        let second = try await FileTimelineRuntimeRepository(fileURL: url)
        let recovered = try #require(try await second.fetchTurn(id: fixture.turnID))
        #expect(recovered.isQuarantined)
        let released = try await second.releaseQuarantine(
            timelineID: fixture.timelineID,
            turnID: fixture.turnID,
            confirmation: QuarantineReleaseConfirmation(phrase: QuarantineReleaseConfirmation.requiredPhrase),
            now: date(2)
        )
        #expect(!released.isQuarantined)
    }
}
