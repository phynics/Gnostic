// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticKit

/// The built-in deterministic harness the offline replay gate exercises.
///
/// It is the "changed harness" a replay protects against: if its prompt
/// sequence, tool call, or outcome changes, replaying the committed fixture
/// diverges and the gate turns red. Recording and replay share this definition
/// so the fixture and the harness cannot drift apart silently.
enum ReplaySelfCheck {
    /// One model call the harness makes.
    struct Step: Sendable {
        let prompt: String
        let tier: ExperimentModelTier
    }

    static let turnID = "replay-self-check"
    static let runID = "kit-replay-self-check"
    static let regime = ExperimentRegime.selfCheck.backendKind
    static let startedAtUTC = "2026-10-05T00:00:00Z"
    static let outcome = "completed"
    static let steps: [Step] = [
        Step(prompt: "Confirm the experiment kit is wired.", tier: .primary),
        Step(prompt: "Name the port the self-check reports.", tier: .utility),
    ]
    static let responses: [ExperimentScriptedResponse] = [
        .text("The experiment kit runs offline, port 8317."),
        .text("Port 8317."),
    ]
    static let toolInvocation = ExperimentToolInvocation(name: "self-check-probe", arguments: "{}")

    /// A deterministic probe tool: it proves the tool seam records and replays.
    private struct Probe: ExperimentToolTransport {
        func invoke(_: ExperimentToolInvocation) async throws -> String { "port 8317" }
    }

    /// Builds the tape a `--record` invocation writes.
    static func recordedTrace() async -> ExperimentTrace {
        let recorder = ExperimentTraceRecorder(runID: runID)
        await recorder.beginTurn(turnID)
        let model = TracingExperimentModelTransport(
            wrapping: ScriptedExperimentModelTransport(script: responses),
            recorder: recorder
        )
        let tool = TracingExperimentToolExecutor(wrapping: Probe(), recorder: recorder)
        if let first = steps.first { _ = try? await model.generate(prompt: first.prompt, tier: first.tier) }
        _ = try? await tool.invoke(toolInvocation)
        if steps.count > 1 { _ = try? await model.generate(prompt: steps[1].prompt, tier: steps[1].tier) }
        await recorder.recordOutcome(outcome)
        return await recorder.trace(regime: regime, startedAtUTC: startedAtUTC)
    }

    /// The harness a replay runs against a tape.
    static var harness: ExperimentReplayHarness {
        { transport, recorder in
            let tool = TracingExperimentToolExecutor(wrapping: Probe(), recorder: recorder)
            if let first = steps.first { _ = try? await transport.generate(prompt: first.prompt, tier: first.tier) }
            _ = try? await tool.invoke(toolInvocation)
            if steps.count > 1 { _ = try? await transport.generate(prompt: steps[1].prompt, tier: steps[1].tier) }
            return ExperimentReplayHarnessResult(outcome: outcome)
        }
    }
}

extension ExperimentCommand {
    /// `gnostic experiment replay --trace <path>`.
    ///
    /// Replays a recorded tape against the built-in harness with no provider
    /// contact. A divergence exits non-zero and names the difference. `--record`
    /// rewrites the committed fixture from the current harness (maintainer use).
    struct Replay: AsyncParsableCommand {
        static let commandName = "replay"

        static let configuration = CommandConfiguration(
            commandName: commandName,
            abstract: "Replay a recorded trace against a harness with no provider.",
            discussion: """
            The built-in kit replay-self-check harness replays a tape deterministically. \
            A changed prompt, tier, tool call, or outcome is reported as a divergence and \
            exits non-zero. Use --record to regenerate the committed fixture.
            """
        )

        @Option(name: .long, help: "Trace path.")
        var trace: String

        @Option(name: .long, help: "Repository root.")
        var repository: String = "."

        @Flag(name: .long, help: "Record the built-in fixture from the current harness instead of replaying (maintainer use).")
        var record = false

        func run() async throws {
            let root = URL(fileURLWithPath: repository).standardizedFileURL
            let url = URL(fileURLWithPath: trace, relativeTo: root)
            if record {
                let recorded = await ReplaySelfCheck.recordedTrace()
                try ExperimentTraceFile.write(recorded, to: url)
                print("Recorded \(recorded.events.count) events to \(trace).")
                return
            }
            guard let loaded = try ExperimentTraceFile.read(url) else {
                throw ExperimentCommandError.invalidArguments("no trace at \(trace)")
            }
            let report = await ExperimentReplay.replay(loaded, using: ReplaySelfCheck.harness)
            print("Replay \(report.runID) under regime \(loaded.regime ?? "<unrecorded>"): \(report.modelCalls) model call(s), recorded outcome \(report.recordedOutcome), replayed outcome \(report.replayedOutcome).")
            guard report.matches else {
                for divergence in report.divergences {
                    print("Divergence: \(divergence)")
                }
                throw ExperimentCommandError.invalidArguments("replay diverged (\(report.divergences.count) divergence(s))")
            }
            print("Match: no divergences.")
        }
    }
}
