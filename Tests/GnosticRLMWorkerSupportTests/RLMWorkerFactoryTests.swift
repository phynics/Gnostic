// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM
import GnosticRLMChibi
import GnosticRLMGuile
import GnosticRLMProcessWorker
import GnosticRLMWorkerSupport
import Testing

@Suite("RLM worker factory")
struct RLMWorkerFactoryTests {
    private static func makeHost() -> RLMWorkerHostState {
        RLMWorkerHostState(
            leafModel: FixtureLeafModel(),
            budget: .standard,
            tokenEstimator: RLMCharacterTokenEstimator(),
            progressSink: nil
        )
    }

    @Test("builds a driver for every executor the current platform supports")
    func buildsSupportedExecutors() throws {
        let host = Self.makeHost()

        if RLMGuileExecutor.isSupportedOnCurrentPlatform {
            let driver = try RLMWorkerFactory.make(selection: .guile, runID: "factory-guile", host: host)
            #expect(driver is RLMProcessWorkerDriver<RLMGuileExecutor>)
        }
        if RLMChibiExecutor.isSupportedOnCurrentPlatform {
            let driver = try RLMWorkerFactory.make(selection: .chibi, runID: "factory-chibi", host: host)
            #expect(driver is RLMProcessWorkerDriver<RLMChibiExecutor>)
        }
    }

    @Test("resolves the bundled worker script for both executors when no override is set")
    func resolvesBundledScript() throws {
        for selection in RLMWorkerSelection.allCases {
            let path = try #require(RLMWorkerFactory.scriptPath(for: selection, environment: [:]))
            #expect(path.hasSuffix("worker.scm"))
            #expect(
                FileManager.default.fileExists(atPath: path),
                "\(selection.rawValue) worker script is not bundled"
            )
        }
    }

    @Test("prefers an existing environment override for each executor")
    func prefersEnvironmentOverride() throws {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-worker-\(UUID().uuidString).scm")
        try "(define x 1)\n".write(to: override, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: override) }

        let guilePath = RLMWorkerFactory.scriptPath(
            for: .guile,
            environment: ["GNOSTIC_GUILE_WORKER": override.path]
        )
        #expect(guilePath == override.path)

        let chibiPath = RLMWorkerFactory.scriptPath(
            for: .chibi,
            environment: ["GNOSTIC_CHIBI_WORKER": override.path]
        )
        #expect(chibiPath == override.path)
    }

    @Test("an override for one executor does not redirect the other")
    func overridesAreExecutorSpecific() throws {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-worker-\(UUID().uuidString).scm")
        try "(define x 1)\n".write(to: override, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: override) }

        let chibiPath = try #require(
            RLMWorkerFactory.scriptPath(
                for: .chibi,
                environment: ["GNOSTIC_GUILE_WORKER": override.path]
            )
        )
        #expect(chibiPath != override.path)
    }

    @Test("falls back to the bundle when an override points at a missing file")
    func ignoresMissingOverride() throws {
        let path = try #require(
            RLMWorkerFactory.scriptPath(
                for: .guile,
                environment: ["GNOSTIC_GUILE_WORKER": "/nonexistent/gnostic-worker.scm"]
            )
        )
        #expect(path != "/nonexistent/gnostic-worker.scm")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("makeHandle uses the explicit script and reports no process before start")
    func handleReportsNoProcessBeforeStart() async throws {
        let handle = RLMWorkerFactory.makeHandle(
            selection: .guile,
            runID: "factory-handle",
            host: Self.makeHost(),
            workerScriptPath: "/nonexistent/gnostic-worker.scm"
        )
        #expect(handle.driver is RLMProcessWorkerDriver<RLMGuileExecutor>)
        #expect(await handle.processIdentifier == nil)
    }
}

private struct FixtureLeafModel: RLMLeafModelClient {
    func query(prompts: [String], tier _: RLMLeafModelTier) async throws -> [String] {
        prompts.map { _ in "response" }
    }
}
