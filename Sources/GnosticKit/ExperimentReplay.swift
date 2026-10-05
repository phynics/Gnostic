// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A deterministic replay failure.
public enum ExperimentReplayError: Error, Equatable, CustomStringConvertible {
    /// The recorded tape has no response for a call the harness made.
    case exhausted(index: Int)
    /// The tape recorded a failed model call at this step.
    case recordedFailure(index: Int)
    /// The harness asked a different question than the tape recorded at this step.
    case divergence(
        index: Int,
        expectedPrompt: String,
        actualPrompt: String,
        expectedTier: String,
        actualTier: String
    )

    public var description: String {
        switch self {
        case let .exhausted(index):
            "replay exhausted the tape at model call \(index + 1): the harness asked for more responses than were recorded"
        case let .recordedFailure(index):
            "replay reproduced the recorded failure at model call \(index + 1)"
        case let .divergence(index, expectedPrompt, actualPrompt, expectedTier, actualTier):
            "replay diverged at model call \(index + 1): recorded tier \(expectedTier) prompt \(abbreviate(expectedPrompt)), harness sent tier \(actualTier) prompt \(abbreviate(actualPrompt))"
        }
    }

    private func abbreviate(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count <= 80 ? "\"\(singleLine)\"" : "\"\(singleLine.prefix(77))...\""
    }
}

/// A transport that serves a recorded tape instead of contacting a provider.
///
/// It pairs each recorded model request with the response that followed it. A
/// call whose prompt or tier differs from the recorded request fails with
/// ``ExperimentReplayError/divergence(index:expectedPrompt:actualPrompt:expectedTier:actualTier:)``
/// rather than silently returning the wrong response.
public actor ReplayingExperimentModelTransport: ExperimentModelTransport {
    private struct Step {
        let request: ExperimentTraceEvent
        let response: ExperimentTraceEvent
    }

    private let steps: [Step]
    private var index = 0
    private var terminalError: ExperimentReplayError?

    /// Creates a replay transport from a recorded tape.
    public init(trace: ExperimentTrace) {
        var steps: [Step] = []
        var pendingRequest: ExperimentTraceEvent?
        for event in trace.events {
            switch event.kind {
            case .modelRequest:
                pendingRequest = event
            case .modelResponse:
                if let request = pendingRequest {
                    steps.append(Step(request: request, response: event))
                    pendingRequest = nil
                }
            default:
                break
            }
        }
        self.steps = steps
    }

    /// The number of recorded steps.
    public var stepCount: Int { steps.count }

    /// The number of steps served so far.
    public var consumed: Int { index }

    /// The number of recorded steps not yet served.
    public var remaining: Int { steps.count - index }

    /// The failure that stopped the replay, when one did.
    public var error: ExperimentReplayError? { terminalError }

    public func generate(prompt: String, tier: ExperimentModelTier) async throws -> ExperimentGeneration {
        guard index < steps.count else {
            let error = ExperimentReplayError.exhausted(index: index)
            terminalError = error
            throw error
        }
        let step = steps[index]
        guard step.request.detail == prompt, step.request.label == tier.rawValue else {
            let error = ExperimentReplayError.divergence(
                index: index,
                expectedPrompt: step.request.detail,
                actualPrompt: prompt,
                expectedTier: step.request.label,
                actualTier: tier.rawValue
            )
            terminalError = error
            throw error
        }
        index += 1
        guard !step.response.failed else {
            // The tape recorded a failure. Replaying it must fail the same way,
            // not return an empty response as if it had succeeded.
            throw ExperimentReplayError.recordedFailure(index: index - 1)
        }
        return ExperimentGeneration(
            text: step.response.detail,
            promptTokens: step.response.promptTokens,
            completionTokens: step.response.completionTokens
        )
    }
}

/// What a replayed harness reports about its run.
public struct ExperimentReplayHarnessResult: Sendable, Equatable {
    /// The terminal outcome, matching the vocabulary a run record uses.
    public let outcome: String
    /// The failure category, when the outcome is a failure.
    public let failureCategory: String?

    /// Creates one harness result.
    public init(outcome: String, failureCategory: String? = nil) {
        self.outcome = outcome
        self.failureCategory = failureCategory
    }
}

/// Replays a tape against a harness.
///
/// The harness receives a tracing transport over the tape and the run's
/// recorder, so it records what it actually did. The replay never contacts a
/// provider.
public typealias ExperimentReplayHarness = @Sendable (
    _ transport: any ExperimentModelTransport,
    _ recorder: ExperimentTraceRecorder
) async -> ExperimentReplayHarnessResult

/// The result of replaying one tape.
public struct ExperimentReplayReport: Codable, Sendable, Equatable {
    /// The run identity the tape belongs to.
    public let runID: String
    /// The outcome the tape recorded.
    public let recordedOutcome: String
    /// The outcome the harness produced.
    public let replayedOutcome: String
    /// The number of recorded model responses the harness consumed.
    public let modelCalls: Int
    /// The number of recorded model responses the harness did not consume.
    public let unusedResponses: Int
    /// The differences that make the replay not match. Empty means a match.
    public let divergences: [String]

    /// Creates one report.
    public init(
        runID: String,
        recordedOutcome: String,
        replayedOutcome: String,
        modelCalls: Int,
        unusedResponses: Int,
        divergences: [String]
    ) {
        self.runID = runID
        self.recordedOutcome = recordedOutcome
        self.replayedOutcome = replayedOutcome
        self.modelCalls = modelCalls
        self.unusedResponses = unusedResponses
        self.divergences = divergences
    }

    /// Whether the replayed run matches the recorded run.
    public var matches: Bool { divergences.isEmpty }
}

/// Deterministic replay of a recorded tape against a harness.
public enum ExperimentReplay {
    /// Replays `trace` with `harness` and compares the result with the tape.
    ///
    /// - Parameters:
    ///   - trace: The recorded tape.
    ///   - harness: The run under test. It receives a transport over the tape and
    ///     the run's recorder.
    /// - Returns: A report. A changed prompt, a changed tier, an exhausted tape,
    ///   a changed outcome, or unconsumed responses each add a divergence.
    public static func replay(
        _ trace: ExperimentTrace,
        using harness: ExperimentReplayHarness
    ) async -> ExperimentReplayReport {
        let source = ReplayingExperimentModelTransport(trace: trace)
        let recorder = ExperimentTraceRecorder(runID: trace.runID)
        if let firstTurn = trace.events.first?.turnID {
            await recorder.beginTurn(firstTurn)
        }
        let transport = TracingExperimentModelTransport(wrapping: source, recorder: recorder)
        let harnessResult = await harness(transport, recorder)
        await recorder.recordOutcome(harnessResult.outcome, failureCategory: harnessResult.failureCategory)

        var divergences: [String] = []
        if let error = await source.error {
            divergences.append(error.description)
        }
        let recordedOutcome = trace.outcome?.label ?? ""
        if harnessResult.outcome != recordedOutcome {
            divergences.append("outcome changed: recorded \(recordedOutcome), replayed \(harnessResult.outcome)")
        }
        let recordedSteps = trace.events.filter { $0.kind != .modelResponse }.map(signature)
        let replayedSteps = (await recorder.snapshot()).filter { $0.kind != .modelResponse }.map(signature)
        if recordedSteps != replayedSteps {
            divergences.append("the replayed harness did not reproduce the recorded steps")
        }
        let unused = await source.remaining
        if unused > 0, await source.error == nil {
            divergences.append("harness used \(await source.consumed) of \(await source.stepCount) recorded model responses")
        }
        return ExperimentReplayReport(
            runID: trace.runID,
            recordedOutcome: recordedOutcome,
            replayedOutcome: harnessResult.outcome,
            modelCalls: await source.consumed,
            unusedResponses: unused,
            divergences: divergences
        )
    }

    /// A stable description of one event for comparing a replay with its tape.
    ///
    /// Model responses are excluded: the replay serves them from the tape, so
    /// they match by construction. The requests, tool calls and results, and
    /// the outcome must all be reproduced.
    private static func signature(_ event: ExperimentTraceEvent) -> String {
        "\(event.kind.rawValue)|\(event.turnID)|\(event.label)|\(event.detail)|\(event.failed)"
    }
}
