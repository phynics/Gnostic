// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

private actor CancellingRootModel: RLMRootModelClient {
    private let token: RLMCancellationToken
    private let step: RLMRootModelStep

    init(token: RLMCancellationToken, step: RLMRootModelStep) {
        self.token = token
        self.step = step
    }

    func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep {
        token.cancel()
        return step
    }
}

private actor CancellingLeafModel: RLMLeafModelClient {
    private let token: RLMCancellationToken

    init(token: RLMCancellationToken) {
        self.token = token
    }

    func query(prompts: [String], tier: RLMLeafModelTier) async throws -> [String] {
        token.cancel()
        return prompts.map { _ in "late response" }
    }
}

private actor FencingRootModel: RLMRootModelClient {
    private let fence: RLMRunFence
    private let step: RLMRootModelStep

    init(fence: RLMRunFence, step: RLMRootModelStep) {
        self.fence = fence
        self.step = step
    }

    func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep {
        fence.invalidate()
        return step
    }
}

@Suite("RLM cancellation and fencing")
struct RLMCancellationTests {
    private let cell = RLMScriptedCell([.corpusSearch(query: "retirement", limit: 4)])
    private let leafPlan: [RLMRootPlanStep] = [
        .search(query: "retirement lease", limit: 4),
        .readPreviousSearchHits(maxChunks: 1),
        .leafScan(tier: .fast, instruction: "scan"),
    ]

    @Test("a pre-cancelled run never accepts a root result")
    func preCancelled() async throws {
        let token = RLMCancellationToken(cancelled: true)
        let engine = RLMAnalysisEngine(
            budget: .standard,
            rootModel: ScriptedRootModel(plan: [.search(query: "retirement", limit: 4)]),
            leafModel: ScriptedLeafModel(defaultResponse: "unused"),
            cancellation: token
        )
        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )
        #expect(result.outcome == .cancelled)
    }

    @Test("cancellation during root generation fences the result")
    func cancelDuringRoot() async throws {
        let token = RLMCancellationToken()
        let engine = RLMAnalysisEngine(
            budget: .standard,
            rootModel: CancellingRootModel(token: token, step: .cell(cell)),
            leafModel: ScriptedLeafModel(defaultResponse: "unused"),
            cancellation: token
        )
        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )
        #expect(result.outcome == .cancelled)
    }

    @Test("cancellation during leaf calls fences the result")
    func cancelDuringLeaf() async throws {
        let token = RLMCancellationToken()
        let engine = RLMAnalysisEngine(
            budget: .standard,
            rootModel: ScriptedRootModel(plan: leafPlan),
            leafModel: CancellingLeafModel(token: token),
            cancellation: token
        )
        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )
        #expect(result.outcome == .cancelled)
    }

    @Test("a result from an invalidated generation is fenced")
    func fenceInvalidated() async throws {
        let fence = RLMRunFence()
        let engine = RLMAnalysisEngine(
            budget: .standard,
            rootModel: FencingRootModel(fence: fence, step: .cell(cell)),
            leafModel: ScriptedLeafModel(defaultResponse: "unused"),
            fence: fence
        )
        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )
        #expect(result.outcome == .fenced)
    }

    @Test("the run fence age is monotonic")
    func fenceMonotonic() {
        let fence = RLMRunFence()
        let first = fence.current
        let second = fence.invalidate()
        #expect(second == first + 1)
        #expect(!fence.accepts(first))
        #expect(fence.accepts(second))
    }
}
