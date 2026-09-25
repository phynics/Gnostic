// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM

/// Everything decided before a live round starts.
struct RLMScenarioPlan: Sendable {
    let identity: RLMScenarioRoundIdentity
    /// The questions this round runs; a pilot runs one.
    let questions: [RLMScenarioQuestion]
    /// Questions in the full matrix, which a pilot's projection scales to.
    let matrixQuestionCount: Int
    let pilot: RLMScenarioPilotReference?

    /// Runs in execution order: question, then repetition, then executor, so a
    /// round stopped early still holds paired executor observations.
    var runKeys: [RLMScenarioRunKey] {
        identity.questionIDs.flatMap { questionID in
            (1...identity.repetitions).flatMap { repetition in
                identity.executors.map {
                    RLMScenarioRunKey(questionID: questionID, executor: $0, repetition: repetition)
                }
            }
        }
    }

    var ceiling: RLMScenarioCeiling {
        RLMScenarioCeiling(runs: runKeys.count, budget: identity.budget, pricing: identity.pricing)
    }
}

/// Drives one round: resumes a matching artifact, runs what is missing, stops
/// at the authorised cost ceiling, and persists after every run.
struct RLMScenarioLiveRunner: Sendable {
    typealias Execute = @Sendable (RLMScenarioQuestion, RLMScenarioRunKey) async -> RLMScenarioRunRecord
    typealias Persist = @Sendable (RLMScenarioLiveArtifact) throws -> Void

    let plan: RLMScenarioPlan
    /// Nil when the round is unpriced (flat-rate subscription).
    let maximumCostUSD: Double?
    let execute: Execute
    let persist: Persist
    let report: @Sendable (String) -> Void
    var now: @Sendable () -> Date = { Date() }

    func run(resuming existing: RLMScenarioLiveArtifact?) async throws -> RLMScenarioLiveArtifact {
        var artifact = try start(from: existing)
        let questions = Dictionary(uniqueKeysWithValues: plan.questions.map { ($0.id, $0) })
        let done = Set(artifact.runs.map(\.key))
        let pending = plan.runKeys.filter { !done.contains($0) }
        report("\(done.count) of \(plan.runKeys.count) runs already recorded; \(pending.count) to run.")

        for key in pending {
            // Stop before a run that could cross the ceiling, judged by the
            // most expensive run observed so far in this round.
            let largestRun = artifact.runs.map(\.costUSD).max() ?? 0
            if let maximumCostUSD, artifact.costActualUSD + largestRun > maximumCostUSD {
                artifact.status = "stopped-at-cost-ceiling"
                report(String(format: "Stopping: $%.4f spent, and another run could exceed the $%.2f ceiling.", artifact.costActualUSD, maximumCostUSD))
                try save(&artifact)
                return artifact
            }
            guard let question = questions[key.questionID] else {
                throw RLMScenarioError.invalidArguments("unknown question \(key.questionID)")
            }
            report("\(key.questionID) \(key.executor) repetition \(key.repetition)…")
            let record = await execute(question, key)
            artifact.runs.append(record)
            artifact.costActualUSD += record.costUSD
            artifact.costComplete = artifact.costComplete && record.costComplete
            report(String(format: "  %@ in %.1fs, %d calls, $%.4f (round total $%.4f)", record.outcome, record.wallMilliseconds / 1_000, record.totalUsage.calls, record.costUSD, artifact.costActualUSD))
            try save(&artifact)
        }

        artifact.status = "complete"
        if plan.identity.stage == .pilot {
            artifact.costProjection = RLMScenarioProjection.project(runs: artifact.runs, questionsInMatrix: plan.matrixQuestionCount)
        }
        try save(&artifact)
        return artifact
    }

    private func start(from existing: RLMScenarioLiveArtifact?) throws -> RLMScenarioLiveArtifact {
        guard let existing else {
            return RLMScenarioLiveArtifact(
                schemaVersion: 1,
                round: plan.identity,
                status: "in-progress",
                updatedAtUTC: timestamp(),
                ceiling: plan.ceiling,
                authorisedMaximumCostUSD: maximumCostUSD,
                pilot: plan.pilot,
                mechanicalScoringRule: RLMScenarioMechanicalScore.rule,
                measurements: RLMScenarioLiveArtifact.unavailableMeasurements,
                runs: [],
                costActualUSD: 0,
                costComplete: true,
                costProjection: nil
            )
        }
        let differences = plan.identity.differences(from: existing.round)
        guard differences.isEmpty else {
            throw RLMScenarioError.roundMismatch("differs in \(differences.joined(separator: ", "))")
        }
        var resumed = existing
        resumed.status = "in-progress"
        return resumed
    }

    private func save(_ artifact: inout RLMScenarioLiveArtifact) throws {
        artifact.updatedAtUTC = timestamp()
        try persist(artifact)
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: now())
    }
}

enum RLMScenarioArtifactFile {
    static func read(_ url: URL) throws -> RLMScenarioLiveArtifact? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RLMScenarioLiveArtifact.self, from: Data(contentsOf: url))
    }

    static func write(_ artifact: RLMScenarioLiveArtifact, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(artifact)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Loads a pilot and checks it can authorise a matrix with `identity`.
    static func authorisingPilot(
        at url: URL,
        displayPath: String,
        for identity: RLMScenarioRoundIdentity
    ) throws -> RLMScenarioPilotReference {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw RLMScenarioError.pilotRequired("no pilot artifact at \(displayPath)")
        }
        let pilot = try JSONDecoder().decode(RLMScenarioLiveArtifact.self, from: data)
        guard pilot.round.stage == .pilot, pilot.status == "complete", let projection = pilot.costProjection else {
            throw RLMScenarioError.pilotRequired("\(displayPath) is not a complete pilot with a cost projection")
        }
        let differences = identity.sharesComparison(with: pilot.round)
        guard differences.isEmpty else {
            throw RLMScenarioError.pilotRequired("the pilot ran a different comparison (\(differences.joined(separator: ", ")))")
        }
        return RLMScenarioPilotReference(path: displayPath, sha256: RLMDigest.sha256Hex([UInt8](data)), projection: projection)
    }
}
