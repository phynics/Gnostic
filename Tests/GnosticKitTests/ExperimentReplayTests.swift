// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-042 (#522): a recorded tape replays
/// deterministically, and a changed harness reports a divergence instead of
/// passing.
@Suite("Experiment replay")
struct ExperimentReplayTests {
    private func makeTrace(
        responses: [ExperimentScriptedResponse] = [.text("answer-1"), .text("answer-2")],
        calls: Int = 2,
        outcome: String = "completed"
    ) async -> ExperimentTrace {
        let recorder = ExperimentTraceRecorder(runID: "run-1")
        await recorder.beginTurn("case-Q1")
        let model = TracingExperimentModelTransport(
            wrapping: ScriptedExperimentModelTransport(script: responses),
            recorder: recorder
        )
        if calls > 0 { _ = try? await model.generate(prompt: "q1", tier: .primary) }
        if calls > 1 { _ = try? await model.generate(prompt: "q2", tier: .utility) }
        await recorder.recordOutcome(outcome)
        return await recorder.trace(regime: "kit", startedAtUTC: "2026-10-05T00:00:00Z")
    }

    @Test("a tape replays through its own harness with no divergences")
    func matchingReplay() async {
        let trace = await makeTrace()
        let report = await ExperimentReplay.replay(trace) { transport, _ in
            _ = try? await transport.generate(prompt: "q1", tier: .primary)
            _ = try? await transport.generate(prompt: "q2", tier: .utility)
            return ExperimentReplayHarnessResult(outcome: "completed")
        }
        #expect(report.matches)
        #expect(report.divergences.isEmpty)
        #expect(report.modelCalls == 2)
        #expect(report.recordedOutcome == "completed")
        #expect(report.replayedOutcome == "completed")
    }

    @Test("a changed prompt is a reported divergence, never a silent pass")
    func promptDivergence() async {
        let trace = await makeTrace()
        let report = await ExperimentReplay.replay(trace) { transport, _ in
            _ = try? await transport.generate(prompt: "q1-changed", tier: .primary)
            _ = try? await transport.generate(prompt: "q2", tier: .utility)
            return ExperimentReplayHarnessResult(outcome: "completed")
        }
        #expect(!report.matches)
        #expect(report.divergences.contains { $0.contains("diverged at model call 1") })
    }

    @Test("a changed tier is a reported divergence")
    func tierDivergence() async {
        let trace = await makeTrace()
        let report = await ExperimentReplay.replay(trace) { transport, _ in
            _ = try? await transport.generate(prompt: "q1", tier: .fast)
            return ExperimentReplayHarnessResult(outcome: "completed")
        }
        #expect(!report.matches)
        #expect(report.divergences.contains { $0.contains("recorded tier primary") })
    }

    @Test("a changed outcome is a reported divergence")
    func outcomeDivergence() async {
        let trace = await makeTrace()
        let report = await ExperimentReplay.replay(trace) { transport, _ in
            _ = try? await transport.generate(prompt: "q1", tier: .primary)
            _ = try? await transport.generate(prompt: "q2", tier: .utility)
            return ExperimentReplayHarnessResult(outcome: "failed", failureCategory: "model")
        }
        #expect(!report.matches)
        #expect(report.divergences.contains { $0.contains("outcome changed") })
    }

    @Test("a harness that asks for more responses than were recorded fails deterministically")
    func exhaustion() async {
        let trace = await makeTrace(responses: [.text("only")], calls: 1)
        let report = await ExperimentReplay.replay(trace) { transport, _ in
            _ = try? await transport.generate(prompt: "q1", tier: .primary)
            _ = try? await transport.generate(prompt: "q2", tier: .utility)
            return ExperimentReplayHarnessResult(outcome: "completed")
        }
        #expect(!report.matches)
        #expect(report.divergences.contains { $0.contains("exhausted the tape at model call 2") })
    }

    @Test("a recorded failure replays as a failure, not as an empty response")
    func recordedFailureReplays() async {
        let trace = await makeTrace(
            responses: [ExperimentScriptedResponse(outcome: .failure("boom"))],
            calls: 1,
            outcome: "failed"
        )
        let report = await ExperimentReplay.replay(trace) { transport, _ in
            do {
                _ = try await transport.generate(prompt: "q1", tier: .primary)
                return ExperimentReplayHarnessResult(outcome: "completed")
            } catch {
                return ExperimentReplayHarnessResult(outcome: "failed", failureCategory: "model")
            }
        }
        #expect(report.matches)
        #expect(report.replayedOutcome == "failed")
        #expect(report.modelCalls == 1)
    }

    @Test("the replay transport contacts no provider and reports its own failure")
    func replayTransportDirect() async {
        let trace = await makeTrace(responses: [.text("recorded")])
        let transport = ReplayingExperimentModelTransport(trace: trace)
        await #expect(throws: ExperimentReplayError.self) {
            try await transport.generate(prompt: "different", tier: .primary)
        }
        #expect(await transport.error != nil)
        #expect(await transport.consumed == 0)
    }
}
