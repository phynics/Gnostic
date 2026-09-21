// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM
@testable import GnosticRLMGuile

@Suite("RLM Guile host-call mapping")
struct RLMGuileOperationTests {
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
