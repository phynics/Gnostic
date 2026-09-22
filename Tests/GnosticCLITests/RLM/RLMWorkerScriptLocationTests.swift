// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

@Suite("RLM worker script location")
struct RLMWorkerScriptLocationTests {
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

    @Test("prefers an existing environment override")
    func prefersEnvironmentOverride() throws {
        let override = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-worker-\(UUID().uuidString).scm")
        try "(define x 1)\n".write(to: override, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: override) }

        let path = RLMWorkerFactory.scriptPath(
            for: .guile,
            environment: ["GNOSTIC_GUILE_WORKER": override.path]
        )
        #expect(path == override.path)
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
}
