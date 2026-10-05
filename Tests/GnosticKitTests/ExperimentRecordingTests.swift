// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

private struct EchoTool: ExperimentToolTransport {
    func invoke(_ invocation: ExperimentToolInvocation) async throws -> String {
        "result:\(invocation.arguments)"
    }
}

private struct FailingTool: ExperimentToolTransport {
    struct Boom: Error {}
    func invoke(_: ExperimentToolInvocation) async throws -> String { throw Boom() }
}

/// Behavioral evidence for GNO-PLAT-041 (#521): recording is opt-in, and a
/// traced run records model, tool, and outcome events under one Turn.
@Suite("Experiment recording")
struct ExperimentRecordingTests {
    @Test("a traced run records model, tool, and outcome events under one Turn")
    func recordsFullTurn() async throws {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        await recorder.beginTurn("case-Q1")
        let model = TracingExperimentModelTransport(
            wrapping: ScriptedExperimentModelTransport(defaultResponse: "hello"),
            recorder: recorder
        )
        let tool = TracingExperimentToolExecutor(wrapping: EchoTool(), recorder: recorder)

        let generation = try await model.generate(prompt: "hi", tier: .utility)
        let result = try await tool.invoke(ExperimentToolInvocation(name: "read", arguments: #"{"path":"a"}"#))
        await recorder.recordOutcome("completed")

        #expect(generation.text == "hello")
        #expect(result == #"result:{"path":"a"}"#)
        let events = await recorder.snapshot()
        #expect(events.map(\.kind) == [.modelRequest, .modelResponse, .toolCall, .toolResult, .outcome])
        #expect(events.allSatisfy { $0.turnID == "case-Q1" })
        #expect(events[0].label == "utility")
        #expect(events[0].detail == "hi")
        #expect(events[3].detail == #"result:{"path":"a"}"#)
    }

    @Test("a failing model and tool record their failure and still throw")
    func recordsFailures() async {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        let model = TracingExperimentModelTransport(
            wrapping: ScriptedExperimentModelTransport(script: [ExperimentScriptedResponse(outcome: .failure("boom"))]),
            recorder: recorder
        )
        await #expect(throws: ExperimentError.self) {
            try await model.generate(prompt: "hi", tier: .primary)
        }
        let tool = TracingExperimentToolExecutor(wrapping: FailingTool(), recorder: recorder)
        await #expect(throws: FailingTool.Boom.self) {
            try await tool.invoke(ExperimentToolInvocation(name: "read", arguments: "x"))
        }

        let events = await recorder.snapshot()
        #expect(events.map(\.kind) == [.modelRequest, .modelResponse, .toolCall, .toolResult])
        #expect(events[1].kind == .modelResponse && events[1].failed)
        #expect(events[3].kind == .toolResult && events[3].failed)
    }

    @Test("an unwrapped transport records nothing")
    func unwrappedRecordsNothing() async throws {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        let plain = ScriptedExperimentModelTransport(defaultResponse: "hello")
        _ = try await plain.generate(prompt: "hi", tier: .primary)
        #expect(await recorder.snapshot().isEmpty)
    }
}
