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
            workerScriptPath: "/worker.scm"
        )
        #expect(RLMChibiExecutor.launchSpec(for: configuration).cellTimeoutInterruptSignal == .user1)
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
