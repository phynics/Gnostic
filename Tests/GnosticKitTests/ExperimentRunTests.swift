// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-033 (#508): the kit records a run's Regime,
/// manifest, result, and cost, computes a pre-spend ceiling, projects a pilot to
/// a larger comparison, and applies the void-round rule.
@Suite("Experiment run records")
struct ExperimentRunTests {
    private func manifest(
        segment: String = "pilot",
        arm: String = "guile",
        cases: [String] = ["Q1"],
        repetitions: Int = 1,
        pricing: ExperimentPricing? = ExperimentPricing(
            inputUSDPerMillionTokens: 3,
            outputUSDPerMillionTokens: 15,
            ratesDate: "2026-09-25"
        )
    ) -> ExperimentRunManifest {
        ExperimentRunManifest(
            manifestID: "rlm-scenario-manifest-v1",
            manifestVersion: "v7",
            segment: segment,
            regime: ExperimentRegime(
                backendKind: "positronic",
                modules: ["rlm"],
                moduleVersions: ["rlm": "GNO-MOD-RLM@commit"],
                modelTiers: ["primary": "root-model", "utility": "utility", "fast": "fast"],
                provider: "Anthropic",
                endpoint: "https://example.invalid"
            ),
            gitCommit: "commit",
            workingTreeClean: true,
            imageDigest: "sha256:image",
            host: "linux/x86_64",
            samplingParameters: "defaults",
            budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 40, estimatedModelTokens: 200_000),
            caseSetSHA256: "cases",
            corpusRevisionDigest: "corpus",
            caseIDs: cases,
            arms: [arm],
            repetitions: repetitions,
            pricing: pricing
        )
    }

    private func record(caseID: String = "Q1", arm: String = "guile", repetition: Int = 1, cost: Double = 0.5) -> ExperimentRunRecord {
        ExperimentRunRecord(
            caseID: caseID,
            arm: arm,
            repetition: repetition,
            startedAtUTC: "2026-09-25T00:00:00Z",
            outcome: "completed",
            failure: nil,
            answer: "answer",
            evidence: [],
            sourceRevisionDigest: "corpus",
            wallMilliseconds: 10,
            metrics: ExperimentRunMetrics(values: ["rootIterations": 3]),
            rootUsage: ExperimentUsage(calls: 2, promptTokens: 100, completionTokens: 10),
            leafUsage: ExperimentUsage(calls: 1, promptTokens: 50, completionTokens: 5),
            costUSD: cost,
            costComplete: true
        )
    }

    @Test("the worst-case ceiling follows the run budget")
    func ceilingFollowsBudget() {
        let ceiling = ExperimentCeiling(
            runs: 6,
            budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 40, estimatedModelTokens: 200_000),
            pricing: ExperimentPricing(inputUSDPerMillionTokens: 3, outputUSDPerMillionTokens: 15, ratesDate: "2026-09-25")
        )
        #expect(ceiling.maximumModelCalls == 6 * 40)
        #expect(ceiling.maximumEstimatedTokens == 6 * 200_000)
        #expect(abs((ceiling.maximumEstimatedCostUSD ?? 0) - 1_200_000 * 15 / 1_000_000) < 1e-9)
    }

    @Test("an unpriced budget has no dollar ceiling")
    func unpricedBudgetHasNoDollarCeiling() {
        let ceiling = ExperimentCeiling(
            runs: 6,
            budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 40, estimatedModelTokens: 200_000),
            pricing: nil
        )
        #expect(ceiling.maximumEstimatedCostUSD == nil)
    }

    @Test("a projection scales pilot means to the full comparison")
    func projectionScalesPilotMeans() {
        let runs = [record(arm: "guile", cost: 0.5), record(arm: "chibi", cost: 0.5)]
        let projection = ExperimentProjection.project(runs: runs, casesInComparison: 12, repetitions: 3)
        #expect(projection.projectedRuns == 72)
        #expect(abs(projection.projectedCostUSD - 36) < 1e-9)
        #expect(projection.arms.map(\.arm) == ["chibi", "guile"])
        #expect(projection.costComplete)
    }

    @Test("the void-round rule names differing fields and ignores the comparison shape")
    func voidRoundDifferences() {
        let pilot = manifest(segment: "pilot", cases: ["Q1"], repetitions: 1)
        let matrix = manifest(segment: "matrix", cases: ["Q1", "Q2"], repetitions: 3)
        #expect(matrix.sharesComparison(with: pilot).isEmpty)
        #expect(matrix.differences(from: pilot).sorted() == ["cases", "repetitions", "segment"])

        let otherModel = ExperimentRunManifest(
            manifestID: matrix.manifestID,
            manifestVersion: matrix.manifestVersion,
            segment: matrix.segment,
            regime: ExperimentRegime(backendKind: "positronic", modelTiers: ["primary": "other"]),
            gitCommit: matrix.gitCommit,
            workingTreeClean: true,
            imageDigest: matrix.imageDigest,
            host: matrix.host,
            samplingParameters: matrix.samplingParameters,
            budget: matrix.budget,
            caseSetSHA256: matrix.caseSetSHA256,
            corpusRevisionDigest: matrix.corpusRevisionDigest,
            caseIDs: matrix.caseIDs,
            arms: matrix.arms,
            repetitions: matrix.repetitions,
            pricing: matrix.pricing
        )
        #expect(matrix.sharesComparison(with: otherModel) == ["regime"])
    }

    @Test("a run artifact round-trips through JSON with a trailing newline")
    func artifactRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-run-\(UUID().uuidString)")
            .appendingPathComponent("artifact.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let round = manifest()
        let artifact = ExperimentRunArtifact(
            schemaVersion: 1,
            manifest: round,
            status: "in-progress",
            updatedAtUTC: "2026-09-25T00:00:00Z",
            ceiling: ExperimentCeiling(runs: 1, budget: round.budget, pricing: round.pricing),
            authorisedMaximumCostUSD: 1,
            pilot: nil,
            scoringRule: "assertions",
            measurements: [],
            runs: [record()],
            costActualUSD: 0.5,
            costComplete: true
        )
        try ExperimentArtifactFile.write(artifact, to: url)

        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0A)
        #expect(try ExperimentArtifactFile.read(url) == artifact)
    }

    @Test("a missing pilot artifact is refused")
    func missingPilotRefused() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-pilot-\(UUID().uuidString).json")
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentArtifactFile.authorisingPilot(at: url, displayPath: "pilot.json", for: manifest(segment: "matrix"))
        }
    }
}
