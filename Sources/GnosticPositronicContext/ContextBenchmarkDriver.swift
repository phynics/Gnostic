// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit

/// The deterministic baseline arms the scaffold measures.
public enum ContextBaselineArm: String, Codable, Sendable, Equatable, CaseIterable {
    /// The whole transcript, unbounded.
    case rawHistory = "raw-history"
    /// PositronicKit prompt-budget compression with a small window.
    case pkCompression = "pk-compression"
    /// A single head-plus-tail summary of the whole history.
    case oneShotSummary = "one-shot-summary"
}

/// The offline long-horizon baseline harness.
///
/// Every arm projects the same transcript and scores the projection with the
/// shared planted-obligation checks. No provider is contacted, so the harness
/// runs inside `make verify`. The projection *is* the model-facing context and
/// is scored as the answer, so the score measures what the context retains.
public struct ContextBenchmarkDriver: ExperimentScenarioDriver {
    /// The benchmark cases, one per shared planted obligation.
    public let cases: [ExperimentScenarioCase]
    /// The arms, in execution order.
    public let arms: [String]
    /// The long-horizon transcript.
    public let transcript: ContextTranscript
    /// The checks each case scores, keyed by case ID.
    public let checksByCaseID: [String: [ExperimentScenarioCheck]]
    /// The PositronicKit token budget for the `pk-compression` arm.
    public let pkBudgetTokens: Int

    /// Creates the harness.
    ///
    /// - Parameters:
    ///   - transcript: The long-horizon transcript.
    ///   - cases: The benchmark cases.
    ///   - checksByCaseID: The checks each case scores.
    ///   - arms: The baseline arms to measure.
    ///   - pkBudgetTokens: The PositronicKit token budget.
    public init(
        transcript: ContextTranscript = ContextFixtureTranscript.longHorizon(),
        cases: [ExperimentScenarioCase] = ContextFixtureTranscript.cases,
        checksByCaseID: [String: [ExperimentScenarioCheck]] = ContextFixtureTranscript.checksByCaseID,
        arms: [ContextBaselineArm] = [.rawHistory, .pkCompression, .oneShotSummary],
        pkBudgetTokens: Int = ContextPKCompression.defaultBudgetTokens
    ) {
        self.transcript = transcript
        self.cases = cases
        self.checksByCaseID = checksByCaseID
        self.arms = arms.map(\.rawValue)
        self.pkBudgetTokens = pkBudgetTokens
    }

    /// Returns the model-facing projection for one arm.
    ///
    /// - Parameter arm: The arm name.
    /// - Returns: The projected context, or the empty string for an unknown arm.
    public func projection(for arm: String) -> String {
        switch arm {
        case ContextBaselineArm.rawHistory.rawValue:
            transcript.rendered
        case ContextBaselineArm.pkCompression.rawValue:
            (try? ContextPKCompression.project(transcript, budgetTokens: pkBudgetTokens)) ?? ""
        case ContextBaselineArm.oneShotSummary.rawValue:
            ContextOneShotSummary.project(transcript)
        default:
            ""
        }
    }

    public func run(_ scenarioCase: ExperimentScenarioCase, key: ExperimentRunKey) async -> ExperimentRunRecord {
        let answer = projection(for: key.arm)
        let checks = checksByCaseID[scenarioCase.id] ?? []
        let score = ExperimentAssertionScorer().score(answer: answer, checks: checks)
        return ExperimentRunRecord(
            caseID: scenarioCase.id,
            arm: key.arm,
            repetition: key.repetition,
            startedAtUTC: "1970-01-01T00:00:00Z",
            outcome: "completed",
            failureCategory: nil,
            failure: nil,
            answer: answer,
            evidence: [],
            sourceRevisionDigest: nil,
            wallMilliseconds: 0,
            metrics: ExperimentRunMetrics(values: [
                "checksPassed": Double(score.passed),
                "checksTotal": Double(score.total),
                "recall": score.overallRecall ?? 0,
                "projectionCharacters": Double(answer.count),
            ]),
            rootUsage: ExperimentUsage(),
            leafUsage: ExperimentUsage(),
            costUSD: 0,
            costComplete: true,
            score: score.passed
        )
    }
}
