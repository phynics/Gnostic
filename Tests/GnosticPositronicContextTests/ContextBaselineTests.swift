// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit
import Testing
import GnosticPositronicBackend

@testable import GnosticPositronicContext

@Suite("Context baseline harness")
struct ContextBaselineTests {
    @Test("the harness scores the shared planted-obligation cases")
    func casesMatchSharedFixtures() {
        let driver = ContextBenchmarkDriver()
        #expect(driver.cases.map(\.id) == ExperimentFixtureLibrary.plantedObligations.map(\.id))
        #expect(driver.arms == ["raw-history", "pk-compression", "one-shot-summary"])
    }

    @Test("the long-horizon transcript overflows the small PositronicKit window")
    func transcriptOverflowsSmallWindow() {
        let transcript = ContextFixtureTranscript.longHorizon()
        #expect(transcript.turns.count >= 40)
        let estimatedTokens = transcript.rendered.count / 4
        #expect(estimatedTokens > ContextPKCompression.defaultBudgetTokens)
    }

    @Test("raw history retains the port but repeats the injected tool text")
    func rawRetainsObligationsButRepeatsInjection() throws {
        let driver = ContextBenchmarkDriver(arms: [.rawHistory])
        let projection = driver.projection(for: ContextBaselineArm.rawHistory.rawValue)
        #expect(projection.contains("8317"))

        let checks = try #require(ContextFixtureTranscript.checksByCaseID["malicious-tool-text"])
        let score = ExperimentAssertionScorer().score(answer: projection, checks: checks)
        #expect(score.results.first { $0.id == "malicious" }?.passed == false)
        #expect(score.results.first { $0.id == "distrusts" }?.passed == true)
    }

    @Test("the budgeted baselines lose obligations the raw history keeps")
    func budgetedBaselinesLoseObligations() async {
        let driver = ContextBenchmarkDriver()
        let raw = await totals(driver, arm: ContextBaselineArm.rawHistory.rawValue)
        let pk = await totals(driver, arm: ContextBaselineArm.pkCompression.rawValue)
        let oneShot = await totals(driver, arm: ContextBaselineArm.oneShotSummary.rawValue)

        #expect(raw.total == pk.total)
        #expect(raw.total == oneShot.total)
        #expect(raw.passed > pk.passed, "pk-compression must lose at least one obligation the raw history keeps")
        #expect(raw.passed > oneShot.passed, "one-shot-summary must lose at least one obligation the raw history keeps")
    }

    @Test("every arm completes every case offline at zero cost")
    func everyArmCompletesEveryCaseOffline() async {
        let driver = ContextBenchmarkDriver()
        for arm in driver.arms {
            for scenario in driver.cases {
                let record = await driver.run(scenario, key: ExperimentRunKey(caseID: scenario.id, arm: arm, repetition: 1))
                #expect(record.outcome == "completed", "\(arm)/\(scenario.id) did not complete")
                #expect(record.costUSD == 0)
                #expect(record.rootUsage.calls == 0)
                #expect(record.answer != nil)
                #expect(record.metrics["checksTotal"] != nil)
            }
        }
    }

    private func totals(_ driver: ContextBenchmarkDriver, arm: String) async -> (passed: Int, total: Int) {
        var passed = 0
        var total = 0
        for scenario in driver.cases {
            let record = await driver.run(scenario, key: ExperimentRunKey(caseID: scenario.id, arm: arm, repetition: 1))
            passed += record.score ?? 0
            total += Int(record.metrics["checksTotal"] ?? 0)
        }
        return (passed, total)
    }
}
