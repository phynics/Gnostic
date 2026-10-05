// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-035 (#510): the kit runner resumes a
/// matching artifact, persists after every run, stops at the authorised cost
/// ceiling, and projects a completed pilot.
@Suite("Experiment runner")
struct ExperimentRunnerTests {
    private func manifest(segment: String = "pilot", arms: [String] = ["guile", "chibi"], cases: [String] = ["Q1"], repetitions: Int = 3) -> ExperimentRunManifest {
        ExperimentRunManifest(
            manifestID: "m",
            manifestVersion: "v1",
            segment: segment,
            regime: ExperimentRegime(backendKind: "positronic"),
            gitCommit: "commit",
            workingTreeClean: true,
            imageDigest: "sha256:image",
            host: "linux/x86_64",
            samplingParameters: "defaults",
            budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 40, estimatedModelTokens: 200_000),
            caseSetSHA256: "cases",
            corpusRevisionDigest: nil,
            caseIDs: cases,
            arms: arms,
            repetitions: repetitions,
            pricing: ExperimentPricing(inputUSDPerMillionTokens: 3, outputUSDPerMillionTokens: 15, ratesDate: "2026-09-25")
        )
    }

    private func record(_ key: ExperimentRunKey, cost: Double) -> ExperimentRunRecord {
        ExperimentRunRecord(
            caseID: key.caseID,
            arm: key.arm,
            repetition: key.repetition,
            startedAtUTC: "2026-09-25T00:00:00Z",
            outcome: "completed",
            failure: nil,
            answer: "answer",
            evidence: [],
            sourceRevisionDigest: nil,
            wallMilliseconds: 10,
            metrics: ExperimentRunMetrics(),
            rootUsage: ExperimentUsage(calls: 2, promptTokens: 100, completionTokens: 10),
            leafUsage: ExperimentUsage(calls: 1, promptTokens: 50, completionTokens: 5),
            costUSD: cost,
            costComplete: true
        )
    }

    private func runner(
        plan: ExperimentPlan,
        maxCost: Double?,
        runCost: Double,
        persisted: (@Sendable (ExperimentRunArtifact) -> Void)? = nil,
        onRun: (@Sendable (ExperimentRunKey) -> Void)? = nil
    ) -> ExperimentRunner {
        ExperimentRunner(
            plan: plan,
            maximumCostUSD: maxCost,
            scoringRule: "assertions",
            execute: { key in
                onRun?(key)
                return record(key, cost: runCost)
            },
            persist: { artifact in persisted?(artifact) }
        )
    }

    @Test("a complete pilot records every run and projects the comparison")
    func pilotCompletesWithProjection() async throws {
        let plan = ExperimentPlan(manifest: manifest(), matrixCaseCount: 12)
        let persistedCount = Counter()
        let artifact = try await runner(plan: plan, maxCost: 100, runCost: 0.5, persisted: { _ in persistedCount.increment() }).run(resuming: nil)

        #expect(artifact.status == "complete")
        #expect(artifact.runs.count == 6)
        #expect(persistedCount.count == 7)
        let projection = try #require(artifact.costProjection)
        #expect(projection.projectedRuns == 12 * 3 * 2)
        #expect(abs(projection.projectedCostUSD - 72 * 0.5) < 1e-9)
    }

    @Test("a priced round stops at the cost ceiling")
    func stopsAtCostCeiling() async throws {
        let plan = ExperimentPlan(manifest: manifest(), matrixCaseCount: 12)
        let artifact = try await runner(plan: plan, maxCost: 1.2, runCost: 0.5).run(resuming: nil)
        #expect(artifact.status == "stopped-at-cost-ceiling")
        #expect(artifact.runs.count == 2)
    }

    @Test("resuming runs only the missing runs")
    func resumeRunsOnlyMissing() async throws {
        let plan = ExperimentPlan(manifest: manifest(), matrixCaseCount: 12)
        let first = try await runner(plan: plan, maxCost: 1.2, runCost: 0.5).run(resuming: nil)

        let calls = Counter()
        let resumed = try await runner(plan: plan, maxCost: 100, runCost: 0.5, onRun: { _ in calls.increment() }).run(resuming: first)
        #expect(resumed.status == "complete")
        #expect(resumed.runs.count == 6)
        #expect(calls.count == 4)
        #expect(Set(resumed.runs.map(\.key)).count == 6)
    }

    @Test("an unpriced round has no dollar ceiling")
    func unpricedRoundHasNoCeiling() async throws {
        var unpriced = manifest()
        unpriced = ExperimentRunManifest(
            manifestID: unpriced.manifestID, manifestVersion: unpriced.manifestVersion, segment: unpriced.segment,
            regime: unpriced.regime, gitCommit: unpriced.gitCommit, workingTreeClean: true,
            imageDigest: unpriced.imageDigest, host: unpriced.host, samplingParameters: unpriced.samplingParameters,
            budget: unpriced.budget, caseSetSHA256: unpriced.caseSetSHA256,
            corpusRevisionDigest: unpriced.corpusRevisionDigest, caseIDs: unpriced.caseIDs, arms: unpriced.arms,
            repetitions: unpriced.repetitions, pricing: nil
        )
        let plan = ExperimentPlan(manifest: unpriced, matrixCaseCount: 12)
        let artifact = try await runner(plan: plan, maxCost: nil, runCost: 0).run(resuming: nil)
        #expect(artifact.status == "complete")
        #expect(artifact.ceiling.maximumEstimatedCostUSD == nil)
    }

    @Test("an artifact from a different round is never resumed")
    func differentRoundRefused() async throws {
        let plan = ExperimentPlan(manifest: manifest(), matrixCaseCount: 12)
        var existing = try await runner(plan: plan, maxCost: 100, runCost: 0.5).run(resuming: nil)
        existing = ExperimentRunArtifact(
            schemaVersion: existing.schemaVersion,
            manifest: manifest(arms: ["other"]),
            status: existing.status,
            updatedAtUTC: existing.updatedAtUTC,
            ceiling: existing.ceiling,
            authorisedMaximumCostUSD: existing.authorisedMaximumCostUSD,
            pilot: nil,
            scoringRule: existing.scoringRule,
            measurements: existing.measurements,
            runs: existing.runs,
            costActualUSD: existing.costActualUSD,
            costComplete: existing.costComplete,
            costProjection: nil
        )
        await #expect(throws: ExperimentError.self) {
            _ = try await runner(plan: plan, maxCost: 100, runCost: 0.5).run(resuming: existing)
        }
    }
}

/// A thread-safe counter for concurrent test closures.
private final class Counter: Sendable {
    private let value = Mutex<Int>(0)

    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
