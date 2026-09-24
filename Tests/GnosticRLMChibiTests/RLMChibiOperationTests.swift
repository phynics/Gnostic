// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM
@testable import GnosticRLMChibi

@Suite("RLM Chibi host-call mapping")
struct RLMChibiOperationTests {
    @Test("Chibi requests a recoverable per-cell timeout interrupt")
    func cellTimeoutInterruptIsInLaunchSpec() {
        let configuration = RLMChibiWorkerConfiguration(
            runID: "r",
            workerScriptPath: "/worker.scm",
            limitExecutablePath: "/gnostic-rlm-limit-exec"
        )
        let launchSpec = RLMChibiExecutor.launchSpec(for: configuration)
        #expect(launchSpec.cellTimeoutInterruptSignal == .user1)
        #expect(launchSpec.launchPath == "/gnostic-rlm-limit-exec")
        #expect(launchSpec.requirements.contains(.limitTool("/gnostic-rlm-limit-exec")))
        #if os(Linux)
        #expect(launchSpec.arguments.prefix(3) == ["--cpu=30", "--as=268435456", "--"])
        #else
        #expect(launchSpec.arguments.prefix(2) == ["--cpu=30", "--"])
        #expect(launchSpec.arguments.contains("--max-address-space"))
        #expect(launchSpec.arguments.contains("-1"))
        #endif
        #expect(launchSpec.arguments.contains(configuration.executablePath))
    }

    @Test("Chibi forwards only environment-key metadata to its worker")
    func environmentKeysAreInLaunchSpec() {
        let configuration = RLMChibiWorkerConfiguration(
            runID: "r",
            workerScriptPath: "/worker.scm",
            executablePath: "/chibi-scheme",
            limitExecutablePath: "/gnostic-rlm-limit-exec",
            environment: ["PATH": "/usr/bin:/bin", "GNOSTIC_RLM_SECRET": "do-not-forward"]
        )
        let arguments = RLMChibiExecutor.launchSpec(for: configuration).arguments
        var environmentKeys: [String] = []
        for index in arguments.indices where arguments[index] == "--environment-key" {
            let valueIndex = arguments.index(after: index)
            if valueIndex < arguments.endIndex {
                environmentKeys.append(arguments[valueIndex])
            }
        }

        #expect(Set(environmentKeys) == ["CHIBI_MAX_ALLOC", "GNOSTIC_RLM_SECRET", "PATH"])
        #expect(!arguments.contains("do-not-forward"))
    }

    @Test("a one-argument leaf query defaults to the fast tier")
    func defaultTier() {
        let operation = RLMChibiWorkerSession.operation(for: RLMSchemeHostCall(
            runID: "r",
            callID: 1,
            name: "lm-query",
            arguments: [.string("prompt")]
        ))
        #expect(operation == .leafQuery(prompts: ["prompt"], tier: .fast))
    }

    @Test("an explicit leaf query tier is honored")
    func explicitTier() {
        let operation = RLMChibiWorkerSession.operation(for: RLMSchemeHostCall(
            runID: "r",
            callID: 1,
            name: "lm-query",
            arguments: [.string("prompt"), .symbol("primary")]
        ))
        #expect(operation == .leafQuery(prompts: ["prompt"], tier: .primary))
    }

    @Test("a three-argument leaf query is not coerced to a tier")
    func threeArgumentsRejected() {
        let operation = RLMChibiWorkerSession.operation(for: RLMSchemeHostCall(
            runID: "r",
            callID: 1,
            name: "lm-query",
            arguments: [.string("prompt"), .symbol("fast"), .symbol("primary")]
        ))
        #expect(operation == nil)
    }
}
