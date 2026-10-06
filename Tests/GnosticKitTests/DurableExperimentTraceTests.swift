// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

@Suite("Durable experiment trace")
struct DurableExperimentTraceTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-experiment-trace-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("trace.jsonl")
    }

    @Test("a crashed run resumes its tape from the journal")
    func crashRecovery() async throws {
        let url = makeURL()
        let writer = ExperimentTraceRecorder(runID: "run-1")
        try await writer.enableJournal(at: url)
        await writer.beginTurn()
        await writer.recordModelRequest(prompt: "hi", tier: .fast)
        await writer.recordModelResponse(text: "hello", promptTokens: 1, completionTokens: 2)
        await writer.recordToolCall(name: "search", arguments: "{}")
        let partial = await writer.snapshot()
        #expect(partial.count == 3)

        let reader = ExperimentTraceRecorder(runID: "run-1")
        try await reader.enableJournal(at: url)
        #expect(await reader.snapshot() == partial)

        await reader.recordToolResult(name: "search", result: "ok")
        let complete = await reader.snapshot()
        #expect(complete.count == 4)

        let third = ExperimentTraceRecorder(runID: "run-1")
        try await third.enableJournal(at: url)
        #expect(await third.snapshot() == complete)
    }

    @Test("recovery continues the current Turn")
    func recoveryContinuesTurn() async throws {
        let url = makeURL()
        let writer = ExperimentTraceRecorder(runID: "run-2")
        try await writer.enableJournal(at: url)
        let first = await writer.beginTurn()
        await writer.recordModelRequest(prompt: "hi", tier: .primary)

        let reader = ExperimentTraceRecorder(runID: "run-2")
        try await reader.enableJournal(at: url)
        #expect(await reader.turnID == first)
        #expect(await reader.beginTurn() != first)
    }

    @Test("a recorder without a journal keeps its in-memory tape")
    func journalIsOptional() async throws {
        let recorder = ExperimentTraceRecorder(runID: "run-3")
        await recorder.beginTurn()
        await recorder.recordModelRequest(prompt: "hi", tier: .utility)
        #expect(await recorder.snapshot().count == 1)
    }
}
