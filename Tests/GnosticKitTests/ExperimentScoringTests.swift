// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-032 (#507): assertion-based scoring with
/// per-obligation-class recall, and no similarity metric.
@Suite("Experiment scoring")
struct ExperimentScoringTests {
    @Test("assertions evaluate exact, normalized, absent, and exact-value checks")
    func assertionsEvaluate() {
        #expect(ExperimentAssertion.contains("Zenoh").holds(for: "moved to Zenoh"))
        #expect(!ExperimentAssertion.absent("SQLite").holds(for: "we used SQLite"))
        #expect(ExperimentAssertion.containsNormalized("port 8317").holds(for: "Port   8317"))
        #expect(ExperimentAssertion.containsAll(["MQTT", "Zenoh"]).holds(for: "MQTT to Zenoh"))
        #expect(ExperimentAssertion.equals("42").holds(for: " 42 "))
    }

    @Test("the scorer reports recall per obligation class")
    func recallByObligation() {
        let checks = [
            ExperimentScenarioCheck(id: "c1", obligation: .fact, description: "port", assertion: .contains("8317")),
            ExperimentScenarioCheck(id: "c2", obligation: .negativeConstraint, description: "no sqlite", assertion: .absent("SQLite")),
            ExperimentScenarioCheck(id: "c3", obligation: .fact, description: "timeout", assertion: .contains("30")),
        ]
        let score = ExperimentAssertionScorer().score(answer: "port 8317 with a 30s timeout", checks: checks)
        #expect(score.passed == 3)
        #expect(score.total == 3)
        #expect(score.overallRecall == 1)
        #expect(score.recallByObligation[.fact] == 1)
        #expect(score.recallByObligation[.negativeConstraint] == 1)

        let partial = ExperimentAssertionScorer().score(answer: "port 8317, a 30s timeout, and SQLite", checks: checks)
        #expect(partial.recallByObligation[.fact] == 1)
        #expect(partial.recallByObligation[.negativeConstraint] == 0)
        #expect(partial.passed == 2)
    }

    @Test("an empty check list has no recall")
    func emptyChecks() {
        let score = ExperimentAssertionScorer().score(answer: "anything", checks: [])
        #expect(score.overallRecall == nil)
    }

    @Test("the blind sheet hides the arm and scores round-trip onto runs")
    func blindSheetAndApply() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scoring-\(UUID().uuidString)")
        let artifact = makeArtifact()
        try ExperimentArtifactFile.write(artifact, to: url.appendingPathComponent("a.json"))
        defer { try? FileManager.default.removeItem(at: url) }

        let cases = [ExperimentScenarioCase(id: "Q1", prompt: "p", reference: "r", evidencePaths: ["A.md"])]
        let sheet = ExperimentBlindRating.sheet(for: artifact, cases: cases)
        #expect(sheet.items.count == 1)
        let encoded = String(decoding: try JSONEncoder().encode(sheet), as: UTF8.self)
        #expect(!encoded.contains("guile") && !encoded.contains("chibi"))

        let id = try #require(sheet.items.first?.id)
        let scored = try ExperimentBlindRating.apply([id: 7], to: artifact)
        #expect(scored.runs.compactMap(\.score) == [7])
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentBlindRating.apply([id: 11], to: artifact)
        }
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentBlindRating.apply(["unknown": 5], to: artifact)
        }
    }

    private func makeArtifact() -> ExperimentRunArtifact {
        let round = ExperimentRunManifest(
            manifestID: "m",
            manifestVersion: "v1",
            segment: "pilot",
            regime: ExperimentRegime(backendKind: "positronic"),
            gitCommit: "commit",
            workingTreeClean: true,
            imageDigest: "sha256:image",
            host: "linux/x86_64",
            samplingParameters: "defaults",
            budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 40, estimatedModelTokens: 200_000),
            caseSetSHA256: "cases",
            corpusRevisionDigest: nil,
            caseIDs: ["Q1"],
            arms: ["guile"],
            repetitions: 1,
            pricing: nil
        )
        let record = ExperimentRunRecord(
            caseID: "Q1",
            arm: "guile",
            repetition: 1,
            startedAtUTC: "2026-09-25T00:00:00Z",
            outcome: "completed",
            failure: nil,
            answer: "answer",
            evidence: [],
            sourceRevisionDigest: nil,
            wallMilliseconds: 10,
            metrics: ExperimentRunMetrics(),
            rootUsage: ExperimentUsage(calls: 2),
            leafUsage: ExperimentUsage(),
            costUSD: 0,
            costComplete: true
        )
        return ExperimentRunArtifact(
            schemaVersion: 1,
            manifest: round,
            status: "complete",
            updatedAtUTC: "2026-09-25T00:00:00Z",
            ceiling: ExperimentCeiling(runs: 1, budget: round.budget, pricing: nil),
            authorisedMaximumCostUSD: nil,
            pilot: nil,
            scoringRule: ExperimentBlindRating.rule,
            measurements: [],
            runs: [record],
            costActualUSD: 0,
            costComplete: true
        )
    }
}
