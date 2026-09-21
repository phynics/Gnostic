// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM root loop")
struct RLMRootLoopTests {
    private func makeSnapshot() async throws -> RLMCorpusSnapshot {
        try await RLMCorpusSnapshotter().capture(
            from: RLMFixtures.repositorySource(),
            workspaceID: "ws-a",
            budget: .standard
        )
    }

    private func evidence(for snapshot: RLMCorpusSnapshot) -> RLMEvidenceReference {
        let chunk = snapshot.chunks[0]
        return RLMEvidenceReference(
            chunkID: chunk.id,
            path: chunk.path,
            startLine: chunk.startLine,
            endLine: chunk.endLine
        )
    }

    @Test("start requests the first root cell")
    func startRequestsRoot() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        guard case let .requestRootCell(request) = loop.start() else {
            Issue.record("expected a root cell request")
            return
        }
        #expect(request.question == "q")
        #expect(request.metadata.snapshotID == snapshot.id)
        #expect(loop.runMetrics.rootIterations == 1)
        #expect(loop.phase == .awaitingRootCell)
    }

    @Test("an invalid cell requests a correction")
    func invalidThenCorrection() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        _ = loop.start()
        guard case .requestRootCell = loop.receiveRootStep(.invalid(reason: "bad cell")) else {
            Issue.record("expected a correction request")
            return
        }
        #expect(loop.runMetrics.rootCellRejections == 1)
        #expect(loop.runMetrics.rootIterations == 2)
    }

    @Test("a finish cell completes with validated evidence")
    func finishCompletes() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        _ = loop.start()
        let reference = evidence(for: snapshot)
        let answer = "The retirement lease is invalidated before generation fencing."
        let cell = RLMScriptedCell([.finish(answer: answer, evidence: [reference])])

        guard case .scheduleCell = loop.receiveRootStep(.cell(cell)) else {
            Issue.record("expected a scheduling directive")
            return
        }
        guard case let .completed(completedAnswer, completedEvidence) = loop.receiveScheduledOperations(cell.operations) else {
            Issue.record("expected completion")
            return
        }
        #expect(completedAnswer == answer)
        #expect(completedEvidence == [reference])
        #expect(loop.runMetrics.evidenceReferences == 1)
        #expect(loop.isTerminated)
    }

    @Test("a Scheme cell uses the worker scheduling directive")
    func schemeCellSchedulesWorker() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        _ = loop.start()

        guard case let .scheduleScheme(source) = loop.receiveRootStep(.scheme(source: "(finish answer (list))")) else {
            Issue.record("expected a Scheme scheduling directive")
            return
        }
        #expect(source.contains("finish"))
        #expect(loop.phase == .scheduling)
    }

    @Test("unknown evidence fails structurally")
    func unknownEvidenceFails() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        _ = loop.start()
        let reference = RLMEvidenceReference(chunkID: "c-invented", path: "x", startLine: 1, endLine: 1)
        let cell = RLMScriptedCell([.finish(answer: "answer", evidence: [reference])])
        _ = loop.receiveRootStep(.cell(cell))
        guard case let .failed(failure) = loop.receiveScheduledOperations(cell.operations) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .evidenceRejected(.unknownChunk("c-invented")))
    }

    @Test("root iteration exhaustion fails structurally")
    func iterationExhaustion() async throws {
        let snapshot = try await makeSnapshot()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxRootIterations: 1))
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: budget)
        _ = loop.start()
        guard case let .failed(failure) = loop.receiveRootStep(.invalid(reason: "bad cell")) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .rootIterationLimitReached(limit: 1))
    }

    @Test("late results are fenced after termination")
    func lateResultsFenced() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        _ = loop.start()
        let cell = RLMScriptedCell([.finish(answer: "answer", evidence: [])])
        _ = loop.receiveRootStep(.cell(cell))
        _ = loop.receiveScheduledOperations(cell.operations)
        #expect(loop.isTerminated)
        #expect(loop.receiveObservation(.progress) == .lateResultFenced)
        #expect(loop.cancel() == .lateResultFenced)
        #expect(loop.fail(.cancelled) == .lateResultFenced)
    }

    @Test("an oversized cell is rejected structurally")
    func oversizedCell() async throws {
        let snapshot = try await makeSnapshot()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxSchemeCellBytes: 4))
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: budget)
        _ = loop.start()
        let cell = RLMScriptedCell([.corpusSearch(query: "retirement lease generation", limit: 4)])
        guard case let .failed(failure) = loop.receiveRootStep(.cell(cell)) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .cellRejected("cell exceeds 4 bytes"))
    }

    @Test("services a search then finishes")
    func searchThenFinish() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        _ = loop.start()
        let reference = evidence(for: snapshot)
        let cell = RLMScriptedCell([
            .corpusSearch(query: "retirement", limit: 4),
            .finish(answer: "answer", evidence: [reference]),
        ])
        _ = loop.receiveRootStep(.cell(cell))
        guard case .service(.corpusSearch) = loop.receiveScheduledOperations(cell.operations) else {
            Issue.record("expected a search service directive")
            return
        }
        guard case .completed = loop.receiveObservation(.corpusSearch(hits: [], bytesRead: 10)) else {
            Issue.record("expected completion after the search")
            return
        }
        #expect(loop.runMetrics.contextReadBytes == 10)
        #expect(loop.runMetrics.corpusSearchCalls == 1)
    }

    @Test("context read limit fails structurally")
    func contextReadLimit() async throws {
        let snapshot = try await makeSnapshot()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxCorpusBytesRead: 5))
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: budget)
        _ = loop.start()
        let cell = RLMScriptedCell([.corpusSearch(query: "retirement", limit: 4)])
        _ = loop.receiveRootStep(.cell(cell))
        _ = loop.receiveScheduledOperations(cell.operations)
        guard case let .failed(failure) = loop.receiveObservation(.corpusSearch(hits: [], bytesRead: 10)) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .contextReadLimitReached(limit: 5))
    }

    @Test("leaf call limit fails structurally")
    func leafCallLimit() async throws {
        let snapshot = try await makeSnapshot()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxLeafModelCalls: 0))
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: budget)
        _ = loop.start()
        let cell = RLMScriptedCell([.leafQuery(prompts: ["p"], tier: .fast)])
        _ = loop.receiveRootStep(.cell(cell))
        guard case let .failed(failure) = loop.receiveScheduledOperations(cell.operations) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .leafCallLimitReached(limit: 0))
    }

    @Test("output limit fails structurally")
    func outputLimit() async throws {
        let snapshot = try await makeSnapshot()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxSchemeOutputBytes: 2))
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: budget)
        _ = loop.start()
        let cell = RLMScriptedCell([.finish(answer: "long answer", evidence: [])])
        _ = loop.receiveRootStep(.cell(cell))
        guard case let .failed(failure) = loop.receiveScheduledOperations(cell.operations) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .outputLimitReached(limit: 2))
    }

    @Test("token limit fails structurally")
    func tokenLimit() async throws {
        let snapshot = try await makeSnapshot()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxEstimatedModelTokens: 1))
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: budget)
        _ = loop.start()
        let cell = RLMScriptedCell([.corpusSearch(query: "retirement lease generation", limit: 4)])
        guard case let .failed(failure) = loop.receiveRootStep(.cell(cell)) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .tokenLimitReached(limit: 1))
    }

    @Test("wall time limit fails structurally")
    func wallTimeLimit() async throws {
        let snapshot = try await makeSnapshot()
        let clock = RLMTestClock()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxWallDuration: .seconds(1)))
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: budget, clock: clock)
        _ = loop.start()
        clock.advance(by: .seconds(1))
        guard case let .failed(failure) = loop.receiveRootStep(.invalid(reason: "late")) else {
            Issue.record("expected a structured failure")
            return
        }
        #expect(failure == .wallTimeLimitReached(limit: .seconds(1)))
    }

    @Test("cancellation terminates and reports the cause")
    func cancellation() async throws {
        let snapshot = try await makeSnapshot()
        var loop = RLMRootLoop(question: "q", snapshot: snapshot, budget: .standard)
        _ = loop.start()
        #expect(loop.cancel() == .cancelled)
        #expect(loop.termination == .cancelled)
    }
}
