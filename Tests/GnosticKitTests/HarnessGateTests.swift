// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// The deterministic harness gate for GNO-PLAT-037 (#512).
///
/// It proves the kit's mechanics and scoring end to end with scripted models
/// and assertion scoring, with zero provider contact, so `make verify` exercises
/// the substrate #437 and #476 build on.
@Suite("Harness gate")
struct HarnessGateTests {
    /// A deliberately small context window the shared fixtures must overflow.
    private static let smallWindowTokens = 128

    @Test("every shared fixture's answer passes its checks and covers an obligation")
    func fixturesPassTheirChecks() {
        let fixtures = ExperimentFixtureLibrary.plantedObligations
        #expect(!fixtures.isEmpty)
        let scorer = ExperimentAssertionScorer()
        for fixture in fixtures {
            #expect(!fixture.checks.isEmpty, "\(fixture.id) has no checks")
            let score = scorer.score(answer: fixture.answer, checks: fixture.checks)
            #expect(score.overallRecall == 1, "\(fixture.id) failed a check: \(score.results)")
        }
    }

    @Test("a degraded answer fails the negative-constraint and exact-value checks")
    func degradedAnswersFail() {
        let scorer = ExperimentAssertionScorer()
        for fixture in ExperimentFixtureLibrary.plantedObligations {
            let degraded = "I am not sure."
            let score = scorer.score(answer: degraded, checks: fixture.checks)
            #expect(score.overallRecall != 1, "\(fixture.id) accepted a non-answer")
        }
    }

    @Test("the shared fixtures cover every obligation class")
    func coversEveryObligation() {
        let covered = Set(ExperimentFixtureLibrary.plantedObligations.map(\.obligation))
        #expect(covered == Set(ExperimentObligation.allCases))
    }

    @Test("the shared fixtures overflow a deliberately small context window")
    func fixturesOverflowSmallWindow() {
        let text = ExperimentFixtureLibrary.plantedObligations
            .map { "\($0.prompt) \($0.answer)" }
            .joined(separator: "\n")
        let estimatedTokens = text.count / 4
        #expect(estimatedTokens > Self.smallWindowTokens, "fixtures must overflow the small window")
    }

    @Test("a scripted gate run completes through the kit with full recall")
    func gateRunCompletes() async throws {
        let driver = ExperimentFixtureLibrary.driver()
        let manifest = ExperimentRunManifest(
            manifestID: "harness-gate-v1",
            manifestVersion: "v1",
            segment: "run",
            regime: ExperimentRegime(backendKind: "kit", modules: ["kit"]),
            gitCommit: "harness",
            workingTreeClean: true,
            imageDigest: nil,
            host: "harness",
            samplingParameters: "defaults",
            budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 0, estimatedModelTokens: 0),
            caseSetSHA256: ExperimentDigest.sha256Hex(driver.cases.map(\.id).joined(separator: ",")),
            corpusRevisionDigest: nil,
            caseIDs: driver.cases.map(\.id),
            arms: driver.arms,
            repetitions: 1,
            pricing: nil
        )
        let plan = ExperimentPlan(manifest: manifest, matrixCaseCount: driver.cases.count)
        let artifact = try await ExperimentRunner(
            plan: plan,
            maximumCostUSD: nil,
            scoringRule: ExperimentAssertionScorer().rule,
            execute: { key in
                let scenarioCase = driver.cases.first { $0.id == key.caseID }!
                return await driver.run(scenarioCase, key: key)
            },
            persist: { _ in }
        ).run(resuming: nil)

        #expect(artifact.status == "complete")
        #expect(artifact.runs.count == driver.cases.count)
        #expect(artifact.runs.allSatisfy { $0.outcome == "completed" && Double($0.score ?? -1) == $0.metrics["checksTotal"] })
    }
}
