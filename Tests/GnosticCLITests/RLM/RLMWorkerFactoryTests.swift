// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM
import GnosticRLMChibi
import GnosticRLMGuile
import GnosticRLMProcessWorker
import Testing

@testable import GnosticCLI

@Suite("RLM worker factory")
struct RLMWorkerFactoryTests {
    @Test("builds a driver for every executor the current platform supports")
    func buildsSupportedExecutors() throws {
        let host = RLMWorkerHostState(
            leafModel: FixtureLeafModel(),
            budget: .standard,
            tokenEstimator: RLMCharacterTokenEstimator(),
            progressSink: nil
        )

        if RLMGuileExecutor.isSupportedOnCurrentPlatform {
            let driver = try RLMWorkerFactory.make(selection: .guile, runID: "factory-guile", host: host)
            #expect(driver is RLMProcessWorkerDriver<RLMGuileExecutor>)
        }
        if RLMChibiExecutor.isSupportedOnCurrentPlatform {
            let driver = try RLMWorkerFactory.make(selection: .chibi, runID: "factory-chibi", host: host)
            #expect(driver is RLMProcessWorkerDriver<RLMChibiExecutor>)
        }
    }
}

private struct FixtureLeafModel: RLMLeafModelClient {
    func query(prompts: [String], tier _: RLMLeafModelTier) async throws -> [String] {
        prompts.map { _ in "response" }
    }
}
