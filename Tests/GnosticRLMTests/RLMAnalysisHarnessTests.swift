// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

private actor OneShotRootModel: RLMRootModelClient {
    private let step: RLMRootModelStep
    private var used = false

    init(step: RLMRootModelStep) {
        self.step = step
    }

    func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep {
        guard !used else { return .invalid(reason: "exhausted") }
        used = true
        return step
    }
}

private struct FailingRootModel: RLMRootModelClient {
    let failure: RLMFailure

    func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep {
        throw failure
    }
}

private struct FailingLeafModel: RLMLeafModelClient {
    let failure: RLMFailure

    func query(prompts: [String], tier: RLMLeafModelTier) async throws -> [String] {
        throw failure
    }
}

@Suite("RLM analysis harness")
struct RLMAnalysisHarnessTests {
    private func makeEngine(
        budget: RLMRunBudget = .standard,
        root: any RLMRootModelClient,
        leaf: any RLMLeafModelClient
    ) -> RLMAnalysisEngine {
        RLMAnalysisEngine(budget: budget, rootModel: root, leafModel: leaf)
    }

    @Test("a deterministic repository fixture completes with validated evidence")
    func deterministicFixture() async throws {
        let root = ScriptedRootModel(plan: [
            .search(query: "retirement lease generation stale", limit: 8),
            .readPreviousSearchHits(maxChunks: 4),
            .leafScan(tier: .fast, instruction: "Extract the lifecycle mechanism and stale-completion defense."),
            .finish(answer: "The retirement path invalidates the lease before generation fencing."),
        ])
        let leaf = ScriptedLeafModel(responses: [
            .text("The lease is invalidated before retirement."),
            .text("Generation fencing rejects stale completions."),
            .text("Retirement is bounded and idempotent."),
            .text("Late work is fenced by advancing the generation."),
        ])
        let engine = makeEngine(root: root, leaf: leaf)

        let result = await engine.run(
            question: "Trace the complete backend retirement path.",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )

        guard case let .completed(answer, evidence) = result.outcome else {
            Issue.record("expected completion, got \(result.outcome)")
            return
        }
        #expect(!answer.isEmpty)
        #expect(evidence.count == 4)
        #expect(result.metrics.rootIterations == 4)
        #expect(result.metrics.leafPrompts == 4)
        #expect(result.metrics.leafModelCalls == 1)
        #expect(result.metrics.corpusSearchCalls == 1)
        #expect(result.metrics.corpusReadCalls == 1)
        #expect(result.metrics.evidenceReferences == 4)
        #expect(result.metrics.snapshotID == result.snapshotID)
    }

    @Test("validates every evidence reference against the committed snapshot")
    func forgedEvidenceIsRejected() async throws {
        let forged = RLMEvidenceReference(
            chunkID: "c-invented",
            path: "Sources/fake.swift",
            startLine: 1,
            endLine: 99
        )
        let root = OneShotRootModel(step: .cell(RLMScriptedCell([.finish(answer: "answer", evidence: [forged])])))
        let leaf = ScriptedLeafModel(defaultResponse: "unused")
        let engine = makeEngine(root: root, leaf: leaf)

        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )

        #expect(result.outcome == .failed(.evidenceRejected(.unknownChunk("c-invented"))))
    }

    @Test("root model failure is an ordinary structured failure")
    func rootFailure() async throws {
        let engine = makeEngine(
            root: FailingRootModel(failure: .rootModelFailed("provider down")),
            leaf: ScriptedLeafModel(defaultResponse: "unused")
        )
        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )
        #expect(result.outcome == .failed(.rootModelFailed("provider down")))
    }

    @Test("leaf model failure is an ordinary structured failure")
    func leafFailure() async throws {
        let root = ScriptedRootModel(plan: [
            .search(query: "retirement lease", limit: 4),
            .readPreviousSearchHits(maxChunks: 1),
            .leafScan(tier: .fast, instruction: "scan"),
        ])
        let engine = makeEngine(root: root, leaf: FailingLeafModel(failure: .leafModelFailed("provider down")))

        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )
        #expect(result.outcome == .failed(.leafModelFailed("provider down")))
    }

    @Test("root iteration exhaustion is reported before completion")
    func iterationExhaustion() async throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxRootIterations: 2))
        let root = ScriptedRootModel(plan: [
            .search(query: "retirement lease", limit: 4),
            .search(query: "generation stale", limit: 4),
        ])
        let engine = makeEngine(budget: budget, root: root, leaf: ScriptedLeafModel(defaultResponse: "unused"))

        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: RLMFixtures.repositorySource()
        )
        #expect(result.outcome == .failed(.rootIterationLimitReached(limit: 2)))
    }

    @Test("a snapshot that violates path safety fails before root execution")
    func unsafeSnapshotFailsBeforeRoot() async throws {
        let root = FailingRootModel(failure: .rootModelFailed("must not run"))
        let engine = makeEngine(root: root, leaf: ScriptedLeafModel(defaultResponse: "unused"))
        let source = RLMFixtures.textSource()
        source.setFile(path: "/absolute.swift", text: "unsafe")

        let result = await engine.run(
            question: "q",
            workspaceID: "ws-fixture",
            source: source
        )
        #expect(result.outcome == .failed(.absolutePathRejected("/absolute.swift")))
        #expect(result.snapshotID == "unavailable")
    }
}
