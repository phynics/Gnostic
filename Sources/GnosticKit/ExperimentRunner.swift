// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Everything decided before a round starts.
public struct ExperimentPlan: Sendable {
    /// The round manifest.
    public let manifest: ExperimentRunManifest
    /// The number of cases in the full comparison a pilot scales to.
    public let matrixCaseCount: Int
    /// The pilot that authorised a larger comparison, when present.
    public let pilot: ExperimentPilotReference?

    /// Creates a plan.
    public init(manifest: ExperimentRunManifest, matrixCaseCount: Int, pilot: ExperimentPilotReference? = nil) {
        self.manifest = manifest
        self.matrixCaseCount = matrixCaseCount
        self.pilot = pilot
    }

    /// Runs in execution order: case, then repetition, then arm, so a round
    /// stopped early still holds paired arm observations.
    public var runKeys: [ExperimentRunKey] {
        manifest.caseIDs.flatMap { caseID in
            (1...manifest.repetitions).flatMap { repetition in
                manifest.arms.map { ExperimentRunKey(caseID: caseID, arm: $0, repetition: repetition) }
            }
        }
    }

    /// The worst-case ceiling for the plan.
    public var ceiling: ExperimentCeiling {
        ExperimentCeiling(runs: runKeys.count, budget: manifest.budget, pricing: manifest.pricing)
    }
}

/// Drives one round: resumes a matching artifact, runs what is missing, stops at
/// the authorised cost ceiling, and persists after every run.
public struct ExperimentRunner: Sendable {
    /// Executes one run and returns its record.
    public typealias Execute = @Sendable (ExperimentRunKey) async -> ExperimentRunRecord
    /// Persists the artifact after every run.
    public typealias Persist = @Sendable (ExperimentRunArtifact) throws -> Void

    /// The plan.
    public let plan: ExperimentPlan
    /// The authorised cost ceiling, or nil for an unpriced round.
    public let maximumCostUSD: Double?
    /// The scoring rule recorded in the artifact.
    public let scoringRule: String
    /// Measurements that are unavailable or need a later step.
    public let measurements: [ExperimentMeasurementStatus]
    /// Executes one run.
    public let execute: Execute
    /// Persists the artifact.
    public let persist: Persist
    /// Reports progress.
    public let report: @Sendable (String) -> Void
    /// The clock, so a test can make timestamps deterministic.
    public var now: @Sendable () -> Date = { Date() }

    /// Creates a runner.
    public init(
        plan: ExperimentPlan,
        maximumCostUSD: Double?,
        scoringRule: String,
        measurements: [ExperimentMeasurementStatus] = [],
        execute: @escaping Execute,
        persist: @escaping Persist,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.plan = plan
        self.maximumCostUSD = maximumCostUSD
        self.scoringRule = scoringRule
        self.measurements = measurements
        self.execute = execute
        self.persist = persist
        self.report = report
    }

    /// Runs the round, resuming an existing artifact when it matches.
    ///
    /// - Parameter existing: The artifact to resume, or nil to start fresh.
    /// - Returns: The completed or cost-stopped artifact.
    /// - Throws: ``ExperimentError/manifestMismatch(_:)`` when the artifact
    ///   belongs to a different round.
    public func run(resuming existing: ExperimentRunArtifact?) async throws -> ExperimentRunArtifact {
        var artifact = try start(from: existing)
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
            report("\(key.caseID) \(key.arm) repetition \(key.repetition)…")
            let record = await execute(key)
            artifact.runs.append(record)
            artifact.costActualUSD += record.costUSD
            artifact.costComplete = artifact.costComplete && record.costComplete
            report(String(format: "  %@ in %.1fs, %d calls, $%.4f (round total $%.4f)", record.outcome, record.wallMilliseconds / 1_000, record.totalUsage.calls, record.costUSD, artifact.costActualUSD))
            try save(&artifact)
        }

        artifact.status = "complete"
        if plan.manifest.segment == "pilot" {
            artifact.costProjection = ExperimentProjection.project(
                runs: artifact.runs,
                casesInComparison: plan.matrixCaseCount,
                repetitions: plan.manifest.repetitions
            )
        }
        try save(&artifact)
        return artifact
    }

    private func start(from existing: ExperimentRunArtifact?) throws -> ExperimentRunArtifact {
        guard let existing else {
            return ExperimentRunArtifact(
                schemaVersion: 1,
                manifest: plan.manifest,
                status: "in-progress",
                updatedAtUTC: timestamp(),
                ceiling: plan.ceiling,
                authorisedMaximumCostUSD: maximumCostUSD,
                pilot: plan.pilot,
                scoringRule: scoringRule,
                measurements: measurements,
                runs: [],
                costActualUSD: 0,
                costComplete: true
            )
        }
        let differences = plan.manifest.differences(from: existing.manifest)
        guard differences.isEmpty else {
            throw ExperimentError.manifestMismatch("differs in \(differences.joined(separator: ", "))")
        }
        var resumed = existing
        resumed.status = "in-progress"
        return resumed
    }

    private func save(_ artifact: inout ExperimentRunArtifact) throws {
        artifact.updatedAtUTC = timestamp()
        try persist(artifact)
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: now())
    }
}
