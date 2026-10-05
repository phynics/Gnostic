// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-040 (#520): a Run's tape is ordered,
/// Turn-correlated, deterministic, and content-addressable.
@Suite("Experiment trace")
struct ExperimentTraceTests {
    @Test("the recorder orders events and correlates them to their Turn")
    func recorderOrdersAndCorrelates() async {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        #expect(await recorder.turnID == "turn-1")
        await recorder.recordModelRequest(prompt: "first", tier: .primary)
        await recorder.recordModelResponse(text: "answer", promptTokens: 3, completionTokens: 2)
        await recorder.beginTurn()
        await recorder.recordToolCall(name: "read", arguments: "{\"path\":\"a\"}")
        await recorder.recordToolResult(name: "read", result: "contents")
        await recorder.recordOutcome("completed")

        let events = await recorder.snapshot()
        #expect(events.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(events.map(\.turnID) == ["turn-1", "turn-1", "turn-2", "turn-2", "turn-2"])
        #expect(events.map(\.kind) == [.modelRequest, .modelResponse, .toolCall, .toolResult, .outcome])
        #expect(events[0].label == "primary")
        #expect(events[0].detail == "first")
        #expect(events[1].promptTokens == 3)
        #expect(events[1].completionTokens == 2)
        #expect(events[3].detail == "contents")
        #expect(events[4].label == "completed")
    }

    @Test("an explicit Turn id is accepted")
    func explicitTurnID() async {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        #expect(await recorder.beginTurn("case-Q1") == "case-Q1")
        await recorder.recordOutcome("completed")
        #expect(await recorder.snapshot().first?.turnID == "case-Q1")
    }

    @Test("a failure is recorded honestly")
    func failureIsRecorded() async {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        await recorder.recordModelResponse(text: "", promptTokens: nil, completionTokens: nil, failed: true)
        await recorder.recordToolResult(name: "read", result: "denied", failed: true)
        let events = await recorder.snapshot()
        #expect(events.allSatisfy { $0.failed })
    }

    @Test("the tape is a deterministic, content-addressable value")
    func deterministicDigest() async throws {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        await recorder.recordModelRequest(prompt: "hello", tier: .utility)
        await recorder.recordModelResponse(text: "world", promptTokens: 1, completionTokens: 1)
        await recorder.recordOutcome("completed")
        let trace = await recorder.trace(regime: "kit", startedAtUTC: "2026-10-05T00:00:00Z")

        #expect(trace.schemaVersion == ExperimentTrace.currentSchemaVersion)
        #expect(trace.modelResponses.count == 1)
        #expect(trace.outcome?.label == "completed")
        let digest = try trace.digest()
        #expect(digest.count == 64)
        #expect(try trace.digest() == digest)

        var changed = trace
        changed = ExperimentTrace(
            runID: trace.runID,
            regime: trace.regime,
            startedAtUTC: trace.startedAtUTC,
            events: trace.events + [ExperimentTraceEvent(sequence: 4, turnID: "turn-1", kind: .outcome, label: "failed", detail: "")]
        )
        #expect(try changed.digest() != digest)
    }

    @Test("a tape round-trips through its file with a trailing newline")
    func fileRoundTrip() async throws {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        await recorder.recordModelRequest(prompt: "hello", tier: .primary)
        await recorder.recordModelResponse(text: "world", promptTokens: 1, completionTokens: 2)
        await recorder.recordOutcome("completed")
        let trace = await recorder.trace()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/trace.json")
        try ExperimentTraceFile.write(trace, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0A)
        #expect(try ExperimentTraceFile.read(url) == trace)
        #expect(try ExperimentTraceFile.read(directory.appendingPathComponent("missing.json")) == nil)
    }
}
