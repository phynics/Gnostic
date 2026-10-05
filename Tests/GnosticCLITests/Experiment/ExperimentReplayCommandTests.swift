// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit
import Testing

@testable import GnosticCLI

/// Behavioral evidence for GNO-PLAT-043 (#523): the committed fixture replays
/// offline with no divergences, and a changed tape is reported rather than
/// passing.
@Suite("Experiment replay command")
struct ExperimentReplayCommandTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let fixtureRelativePath = "Documentation/Experiments/kit-replay-self-check.trace.json"

    private func committedTrace() throws -> ExperimentTrace {
        let url = Self.repositoryRoot.appendingPathComponent(Self.fixtureRelativePath)
        return try #require(try ExperimentTraceFile.read(url), "missing fixture \(Self.fixtureRelativePath)")
    }

    @Test("the committed fixture replays with no divergences")
    func fixtureReplays() async throws {
        let trace = try committedTrace()
        #expect(trace.runID == ReplaySelfCheck.runID)
        let report = await ExperimentReplay.replay(trace, using: ReplaySelfCheck.harness)
        #expect(report.matches)
        #expect(report.divergences.isEmpty)
        #expect(report.modelCalls == ReplaySelfCheck.steps.count)
    }

    @Test("a freshly recorded tape equals the committed fixture")
    func recordedMatchesFixture() async throws {
        let recorded = await ReplaySelfCheck.recordedTrace()
        #expect(
            recorded == (try committedTrace()),
            "the committed fixture is stale; regenerate it with `gnostic experiment replay --trace \(Self.fixtureRelativePath) --record`"
        )
    }

    @Test("a mutated tape diverges and names the difference")
    func mutatedTraceDiverges() async throws {
        let trace = try committedTrace()
        let mutated = ExperimentTrace(
            runID: trace.runID,
            regime: trace.regime,
            startedAtUTC: trace.startedAtUTC,
            events: trace.events.map { event in
                guard event.kind == .modelRequest else { return event }
                return ExperimentTraceEvent(
                    sequence: event.sequence,
                    turnID: event.turnID,
                    kind: event.kind,
                    label: event.label,
                    detail: event.detail + " (changed)",
                    promptTokens: event.promptTokens,
                    completionTokens: event.completionTokens,
                    failed: event.failed
                )
            }
        )
        let report = await ExperimentReplay.replay(mutated, using: ReplaySelfCheck.harness)
        #expect(!report.matches)
        #expect(report.divergences.contains { $0.contains("diverged at model call 1") })
        #expect(report.divergences.contains { $0.contains("did not reproduce the recorded steps") })
    }
}
