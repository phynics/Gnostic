// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM budgets")
struct RLMRunBudgetTests {
    @Test("a request can only narrow host budgets")
    func narrowingOnlyReduces() throws {
        let enlarged = try RLMRunBudget.resolve(
            host: .standard,
            request: RLMRunBudgetRequest(maxWallDuration: .seconds(9999), maxRootIterations: 999, maxLeafModelCalls: 999)
        )
        #expect(enlarged.maxRootIterations == RLMRunBudget.standard.maxRootIterations)
        #expect(enlarged.maxLeafModelCalls == RLMRunBudget.standard.maxLeafModelCalls)
        #expect(enlarged.maxWallDuration == RLMRunBudget.standard.maxWallDuration)

        let narrowed = try RLMRunBudget.resolve(
            host: .standard,
            request: RLMRunBudgetRequest(maxWallDuration: .seconds(5), maxRootIterations: 2, maxLeafModelCalls: 3)
        )
        #expect(narrowed.maxRootIterations == 2)
        #expect(narrowed.maxLeafModelCalls == 3)
        #expect(narrowed.maxWallDuration == .seconds(5))
    }

    @Test("narrowing preserves the host repair limit")
    func narrowingPreservesRepairLimit() {
        let host = RLMRunBudget(
            maxWallDuration: .seconds(30),
            maxRootIterations: 4,
            maxLeafModelCalls: 8,
            maxEstimatedModelTokens: 100,
            maxCorpusFiles: 10,
            maxCorpusFileBytes: 100,
            maxCorpusBytes: 1_000,
            maxCorpusBytesRead: 100,
            maxSchemeCellBytes: 100,
            maxSchemeOutputBytes: 100,
            maxEvidenceReferences: 4,
            maxChunksPerRead: 2,
            maxSearchLimit: 4,
            maxCellRepairs: 1
        )

        #expect(host.narrowed(by: .init(maxRootIterations: 2)).maxCellRepairs == 1)
    }

    @Test("negative request values are invalid")
    func negativeRejected() {
        #expect(throws: RLMFailure.invalidToolArguments("budget request values must not be negative")) {
            try RLMRunBudget.resolve(host: .standard, request: RLMRunBudgetRequest(maxRootIterations: -1))
        }
        #expect(throws: RLMFailure.invalidToolArguments("budget request duration must not be negative")) {
            try RLMRunBudget.resolve(host: .standard, request: RLMRunBudgetRequest(maxWallDuration: .seconds(-1)))
        }
    }

    @Test("root iteration limit fails structurally")
    func rootIterationLimit() throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxRootIterations: 1))
        var ledger = RLMRunBudgetLedger(budget: budget, startedAt: .zero)
        try ledger.consumeRootIteration()
        #expect(throws: RLMFailure.rootIterationLimitReached(limit: 1)) {
            try ledger.consumeRootIteration()
        }
        #expect(ledger.remaining.rootIterations == 0)
    }

    @Test("leaf call limit fails structurally per prompt")
    func leafCallLimit() throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxLeafModelCalls: 2))
        var ledger = RLMRunBudgetLedger(budget: budget, startedAt: .zero)
        try ledger.consumeLeafModelCalls(2)
        #expect(throws: RLMFailure.leafCallLimitReached(limit: 2)) {
            try ledger.consumeLeafModelCalls(1)
        }
    }

    @Test("token limit fails structurally")
    func tokenLimit() throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxEstimatedModelTokens: 10))
        var ledger = RLMRunBudgetLedger(budget: budget, startedAt: .zero)
        try ledger.consumeEstimatedModelTokens(10)
        #expect(throws: RLMFailure.tokenLimitReached(limit: 10)) {
            try ledger.consumeEstimatedModelTokens(1)
        }
    }

    @Test("context read limit fails structurally")
    func contextReadLimit() throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxCorpusBytesRead: 5))
        var ledger = RLMRunBudgetLedger(budget: budget, startedAt: .zero)
        try ledger.consumeContextRead(bytes: 5)
        #expect(throws: RLMFailure.contextReadLimitReached(limit: 5)) {
            try ledger.consumeContextRead(bytes: 1)
        }
    }

    @Test("output limit fails structurally")
    func outputLimit() throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxSchemeOutputBytes: 3))
        var ledger = RLMRunBudgetLedger(budget: budget, startedAt: .zero)
        try ledger.consumeOutput(bytes: 3)
        #expect(throws: RLMFailure.outputLimitReached(limit: 3)) {
            try ledger.consumeOutput(bytes: 1)
        }
    }

    @Test("wall time limit fails structurally")
    func wallTimeLimit() throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxWallDuration: .seconds(1)))
        let ledger = RLMRunBudgetLedger(budget: budget, startedAt: .zero)
        #expect(throws: RLMFailure.wallTimeLimitReached(limit: .seconds(1))) {
            try ledger.checkWallTime(now: .seconds(1))
        }
    }
}
