// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit
import Testing

@testable import GnosticCLI

/// Behavioral evidence for GNO-PLAT-036 (#511): the generic `experiment run`
/// command resolves a module and scenario, runs it offline through the kit, and
/// records a complete artifact; an unknown module or scenario is refused.
@Suite("Experiment run command")
struct ExperimentRunCommandTests {
    @Test("the catalog resolves the built-in self-check scenario")
    func catalogResolvesBuiltIn() throws {
        let entry = try ExperimentScenarioCatalog.entry(module: "kit", scenario: "self-check")
        #expect(entry.requiresRegime == false)
        #expect(entry.matrixCaseCount == 1)
        let driver = try entry.makeDriver(makeRun())
        #expect(driver.cases.map(\.id) == ["self-check"])
        #expect(driver.arms == ["scripted"])
    }

    @Test("an unknown module or scenario is refused")
    func unknownRefused() {
        #expect(throws: ExperimentCommandError.self) {
            _ = try ExperimentScenarioCatalog.entry(module: "kit", scenario: "missing")
        }
        #expect(throws: ExperimentCommandError.self) {
            _ = try ExperimentScenarioCatalog.entry(module: "missing", scenario: "self-check")
        }
    }

    @Test("a scripted run completes offline and scores every check")
    func scriptedRunCompletes() async throws {
        let driver = SelfCheckScenario.driver
        let manifest = ExperimentRunManifest(
            manifestID: "kit-self-check-manifest-v1",
            manifestVersion: "v1",
            segment: "run",
            regime: ExperimentRegime(backendKind: "kit", modules: ["kit"]),
            gitCommit: "commit",
            workingTreeClean: true,
            imageDigest: nil,
            host: "macos/arm64",
            samplingParameters: "defaults",
            budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 0, estimatedModelTokens: 0),
            caseSetSHA256: "cases",
            corpusRevisionDigest: nil,
            caseIDs: driver.cases.map(\.id),
            arms: driver.arms,
            repetitions: 1,
            pricing: nil
        )
        let plan = ExperimentPlan(manifest: manifest, matrixCaseCount: 1)
        let artifact = try await ExperimentRunner(
            plan: plan,
            maximumCostUSD: nil,
            scoringRule: ExperimentAssertionScorer().rule,
            execute: { key in
                await driver.run(driver.cases[0], key: key)
            },
            persist: { _ in }
        ).run(resuming: nil)

        #expect(artifact.status == "complete")
        let record = try #require(artifact.runs.first)
        #expect(record.outcome == "completed")
        #expect(record.score == 3)
        #expect(record.metrics["recall"] == 1)
    }

    private func makeRun() -> ExperimentCommand.Run {
        var command = ExperimentCommand.Run()
        command.module = "kit"
        command.scenario = "self-check"
        return command
    }
}
