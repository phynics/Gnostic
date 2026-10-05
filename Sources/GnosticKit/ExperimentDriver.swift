// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Executes one scenario case under a regime.
///
/// The kit owns the contract; a consumer owns the driver. The Positronic driver
/// runs through the kit's model seam; a future executor module brings its own
/// driver. The kit never names a backend.
public protocol ExperimentScenarioDriver: Sendable {
    /// The scenario's cases.
    var cases: [ExperimentScenarioCase] { get }
    /// The scenario's arms, in execution order.
    var arms: [String] { get }
    /// Executes one run and returns its record.
    func run(_ scenarioCase: ExperimentScenarioCase, key: ExperimentRunKey) async -> ExperimentRunRecord
}

/// A deterministic driver that scores a fixed answer per case with assertions.
///
/// It backs the kit's own harness gate and any offline baseline: no provider is
/// contacted, and the score is exactly the checks the answer passes.
public struct ScriptedScenarioDriver: ExperimentScenarioDriver {
    /// What one scripted case answers and how it is scored.
    public struct CaseScript: Sendable {
        /// The answer the system under test returns.
        public let answer: String
        /// The checks the answer is scored against.
        public let checks: [ExperimentScenarioCheck]
        /// The run cost in USD.
        public let costUSD: Double
        /// A source revision digest, when the scenario has one.
        public let sourceRevisionDigest: String?
        /// The wall time in milliseconds.
        public let wallMilliseconds: Double

        /// Creates one case script.
        public init(
            answer: String,
            checks: [ExperimentScenarioCheck],
            costUSD: Double = 0,
            sourceRevisionDigest: String? = nil,
            wallMilliseconds: Double = 0
        ) {
            self.answer = answer
            self.checks = checks
            self.costUSD = costUSD
            self.sourceRevisionDigest = sourceRevisionDigest
            self.wallMilliseconds = wallMilliseconds
        }
    }

    public let cases: [ExperimentScenarioCase]
    public let arms: [String]
    private let scripts: [String: CaseScript]
    private let startedAt: String

    /// Creates a scripted driver.
    public init(
        cases: [ExperimentScenarioCase],
        arms: [String] = ["scripted"],
        scripts: [String: CaseScript],
        startedAt: String = "1970-01-01T00:00:00Z"
    ) {
        self.cases = cases
        self.arms = arms
        self.scripts = scripts
        self.startedAt = startedAt
    }

    public func run(_ scenarioCase: ExperimentScenarioCase, key: ExperimentRunKey) async -> ExperimentRunRecord {
        guard let script = scripts[scenarioCase.id] else {
            return ExperimentRunRecord(
                caseID: scenarioCase.id,
                arm: key.arm,
                repetition: key.repetition,
                startedAtUTC: startedAt,
                outcome: "failed",
                failureCategory: "missing-script",
                failure: "no script for case \(scenarioCase.id)",
                answer: nil,
                evidence: [],
                sourceRevisionDigest: nil,
                wallMilliseconds: 0,
                metrics: ExperimentRunMetrics(),
                rootUsage: ExperimentUsage(),
                leafUsage: ExperimentUsage(),
                costUSD: 0,
                costComplete: true
            )
        }
        let score = ExperimentAssertionScorer().score(answer: script.answer, checks: script.checks)
        return ExperimentRunRecord(
            caseID: scenarioCase.id,
            arm: key.arm,
            repetition: key.repetition,
            startedAtUTC: startedAt,
            outcome: "completed",
            failureCategory: nil,
            failure: nil,
            answer: script.answer,
            evidence: [],
            sourceRevisionDigest: script.sourceRevisionDigest,
            wallMilliseconds: script.wallMilliseconds,
            metrics: ExperimentRunMetrics(values: [
                "checksPassed": Double(score.passed),
                "checksTotal": Double(score.total),
                "recall": score.overallRecall ?? 0,
            ]),
            rootUsage: ExperimentUsage(calls: script.checks.count),
            leafUsage: ExperimentUsage(),
            costUSD: script.costUSD,
            costComplete: true,
            score: score.passed
        )
    }
}
