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

    @Test("a run record's Regime is the one config regime show resolves for the same Ascendant")
    func runRegimeMatchesConfigRegime() throws {
        let (store, id) = try seededStore()
        _ = try ConfigConsoleLogic.enableModule(ascendantID: id.uuidString, module: "rlm", store: store)
        let shown = try ConfigConsoleLogic.regime(ascendantID: id.uuidString, store: store)

        let recorded = try ExperimentCommand.Run.resolveRegime(argument: id.uuidString, configPath: store.path().path)

        #expect(recorded == shown)
        #expect(recorded.modules == ["rlm"])
        #expect(recorded.backendKind == "positronic")
    }

    @Test("omitting --regime resolves the default operating Ascendant instead of a kit Regime")
    func omittedRegimeResolvesDefaultAscendant() throws {
        let (store, id) = try seededStore()
        _ = try ConfigConsoleLogic.enableModule(ascendantID: id.uuidString, module: "rlm", store: store)
        let shown = try ConfigConsoleLogic.regime(ascendantID: id.uuidString, store: store)

        let recorded = try ExperimentCommand.Run.resolveRegime(argument: nil, configPath: store.path().path)

        #expect(recorded == shown)
        #expect(recorded.backendKind != "kit")
    }

    @Test("with no manifest a self-check run records the named self-check Regime")
    func missingManifestUsesSelfCheckRegime() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("absent.json").path

        let recorded = try ExperimentCommand.Run.resolveRegime(argument: nil, configPath: path)

        #expect(recorded == ExperimentRegime.selfCheck)
    }

    @Test("--regime naming an unknown Ascendant is refused")
    func unknownRegimeAscendantRefused() throws {
        let (store, _) = try seededStore()
        #expect(throws: CLIConfigurationError.self) {
            _ = try ExperimentCommand.Run.resolveRegime(argument: UUID().uuidString, configPath: store.path().path)
        }
    }

    private func seededStore() throws -> (CLIConfigurationStore, UUID) {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        let id = try store.loadManifest().ascendants[0].id
        return (store, id)
    }

    private func makeRun() -> ExperimentCommand.Run {
        var command = ExperimentCommand.Run()
        command.module = "kit"
        command.scenario = "self-check"
        return command
    }
}
