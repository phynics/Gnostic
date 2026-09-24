// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM
@testable import GnosticRLMGuile

@Suite("RLM Guile host-call mapping")
struct RLMGuileOperationTests {
    @Test("Guile receives host-owned process limits before launch")
    func processLimitsAreInLaunchSpec() {
        let configuration = RLMGuileWorkerConfiguration(
            runID: "r",
            workerScriptPath: "/worker.scm",
            limitExecutablePath: "/gnostic-rlm-limit-exec"
        )
        let launchSpec = RLMGuileExecutor.launchSpec(for: configuration)
        #expect(launchSpec.launchPath == "/gnostic-rlm-limit-exec")
        #expect(launchSpec.requirements.contains(.limitTool("/gnostic-rlm-limit-exec")))
        #if os(Linux)
        #expect(launchSpec.arguments.prefix(3) == ["--cpu=30", "--as=268435456", "--"])
        #else
        #expect(launchSpec.arguments.prefix(2) == ["--cpu=30", "--"])
        #endif
        #expect(launchSpec.arguments.contains(configuration.executablePath))
        #expect(launchSpec.arguments.contains("/worker.scm"))
    }

    @Test("Guile refuses to start without the required host limit launcher")
    func missingLimitLauncherIsReported() async {
        let session = RLMGuileWorkerSession(
            configuration: RLMGuileWorkerConfiguration(
                runID: "r",
                workerScriptPath: "/worker.scm",
                executablePath: "/bin/sh",
                limitExecutablePath: "/missing/gnostic-rlm-limit-exec"
            ),
            host: RLMWorkerClosureHost { _ in .progress }
        )
        await #expect(throws: RLMGuileWorkerError.limitToolMissing("/missing/gnostic-rlm-limit-exec")) {
            try await session.start()
        }
    }

    @Test("a one-argument leaf query defaults to the fast tier")
    func defaultTier() {
        let operation = RLMGuileWorkerSession.operation(for: RLMSchemeHostCall(
            runID: "r",
            callID: 1,
            name: "lm-query",
            arguments: [.string("prompt")]
        ))
        #expect(operation == .leafQuery(prompts: ["prompt"], tier: .fast))
    }

    @Test("an explicit leaf query tier is honored")
    func explicitTier() {
        let operation = RLMGuileWorkerSession.operation(for: RLMSchemeHostCall(
            runID: "r",
            callID: 1,
            name: "lm-query",
            arguments: [.string("prompt"), .symbol("primary")]
        ))
        #expect(operation == .leafQuery(prompts: ["prompt"], tier: .primary))
    }

    @Test("a three-argument leaf query is not coerced to a tier")
    func threeArgumentsRejected() {
        let operation = RLMGuileWorkerSession.operation(for: RLMSchemeHostCall(
            runID: "r",
            callID: 1,
            name: "lm-query",
            arguments: [.string("prompt"), .symbol("fast"), .symbol("primary")]
        ))
        #expect(operation == nil)
    }
}
