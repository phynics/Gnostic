// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticRLM
import PKContracts
import Testing

@testable import GnosticCLI

#if os(Linux)
@Suite("Bounded Workspace analysis tool")
struct BoundedWorkspaceAnalysisToolTests {
    @Test("captures one local Workspace and returns validated structured output")
    @MainActor
    func analyzesLocalWorkspace() async throws {
        let workspaceID = UUID()
        let runtime = PositronicContributionRuntimeContext(
            workspaceReader: FixtureWorkspaceReader(workspaceID: workspaceID),
            modelService: FixtureRLMModel(),
            allowedWorkspaceIDs: [workspaceID]
        )
        let tool = AnalyzeWorkspaceCorpusTool(runtime: runtime, worker: .guile)

        let result = try await PositronicTurnInvocationContext.$current.withValue(
            .init(ascendantID: UUID(), timelineID: UUID(), turnID: UUID().uuidString)
        ) {
            try await tool.execute(parameters: [
                "question": AnyCodable("What is in the corpus?"),
                "workspaceID": AnyCodable(workspaceID.uuidString),
                "pathPrefixes": .array([.string("Sources")]),
            ])
        }

        #expect(result.isSuccess)
        #expect(result.output.contains("\"answer\":\"answer\""))
        #expect(result.output.contains("\"evidence\":[]"))
    }

    @Test("rejects a batched leaf request before model fan-out")
    func rejectsOversizedLeafBatch() async throws {
        let snapshot = emptySnapshot()
        let budget = RLMRunBudget.standard.narrowed(by: .init(maxLeafModelCalls: 2))
        let host = RLMWorkerHostState(
            leafModel: FixtureLeafModel(),
            budget: budget,
            tokenEstimator: RLMCharacterTokenEstimator(),
            progressSink: nil
        )
        let evaluator = RLMWorkerCellEvaluator(
            driver: FixtureWorkerDriver(host: host, behavior: .leafBatch(count: 3)),
            host: host
        )
        await evaluator.bind(snapshot: snapshot)

        do {
            _ = try await evaluator.scheduleScheme("(lm-query-batched)")
            Issue.record("expected the leaf batch to be rejected")
        } catch let failure as RLMFailure {
            #expect(failure == .leafCallLimitReached(limit: 2))
        } catch {
            Issue.record("unexpected failure: \(error)")
        }
    }

    @Test("rejects evidence IDs outside the bound snapshot")
    func rejectsUnknownWorkerEvidence() async throws {
        let snapshot = emptySnapshot()
        let host = RLMWorkerHostState(
            leafModel: FixtureLeafModel(),
            budget: .standard,
            tokenEstimator: RLMCharacterTokenEstimator(),
            progressSink: nil
        )
        let evaluator = RLMWorkerCellEvaluator(
            driver: FixtureWorkerDriver(host: host, behavior: .unknownEvidence),
            host: host
        )
        await evaluator.bind(snapshot: snapshot)

        do {
            _ = try await evaluator.scheduleScheme("(finish)")
            Issue.record("expected unknown evidence to be rejected")
        } catch let failure as RLMFailure {
            #expect(failure == .evidenceRejected(.unknownChunk("missing")))
        } catch {
            Issue.record("unexpected failure: \(error)")
        }
    }

    @Test("keeps host-call Scheme failures terminal")
    func keepsHostCallFailuresTerminal() {
        #expect(RLMWorkerFailureClassifier.classify("host call failed: Leaf model call limit reached: 2") == .evaluatorFailed("host call failed: Leaf model call limit reached: 2"))
        #expect(RLMWorkerFailureClassifier.classify("resource limit exceeded") == .evaluatorFailed("resource limit exceeded"))
        #expect(RLMWorkerFailureClassifier.classify("unbound variable: retry") == .cellRuntimeFailed("unbound variable: retry"))
    }

    private func emptySnapshot() -> RLMCorpusSnapshot {
        RLMCorpusSnapshot(
            id: "snapshot",
            workspaceID: "workspace",
            revisionDigest: "digest",
            files: [],
            chunks: [],
            skipped: [],
            allowedPathPrefixes: []
        )
    }
}

private struct FixtureRLMModel: PositronicContributionModelService {
    func generate(prompt _: String, tier _: PositronicContributionModelTier) async throws -> String {
        "(finish \"answer\" (list))"
    }
}

private struct FixtureLeafModel: RLMLeafModelClient {
    func query(prompts: [String], tier _: RLMLeafModelTier) async throws -> [String] {
        prompts.map { _ in "response" }
    }
}

private enum FixtureWorkerBehavior: Sendable {
    case leafBatch(count: Int)
    case unknownEvidence
}

private struct FixtureWorkerDriver: RLMWorkerDriver {
    let host: RLMWorkerHostState
    let behavior: FixtureWorkerBehavior

    func start() async throws {}

    func evaluate(source _: String) async -> RLMWorkerEvaluation {
        switch behavior {
        case let .leafBatch(count):
            do {
                _ = try await host.service(.leafQuery(
                    prompts: Array(repeating: "prompt", count: count),
                    tier: .fast
                ))
                return .value(nil)
            } catch let failure as RLMFailure {
                return .failed(failure)
            } catch {
                return .failed(.evaluatorFailed(String(describing: error)))
            }
        case .unknownEvidence:
            return .finished(answer: "answer", evidenceIDs: ["missing"])
        }
    }

    func cancel() async {}
    func shutdown() async {}
}

@MainActor
private struct FixtureWorkspaceReader: PositronicContributionWorkspaceReader {
    let workspaceID: UUID

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        guard id == workspaceID else { return nil }
        return BackendWorkspaceReference(id: id, uri: "file:///fixture", status: .available)
    }

    func readFile(workspaceID: UUID, path: String) async throws -> String {
        guard workspaceID == self.workspaceID, path == "Sources/example.swift" else {
            throw AscendantBackendError.invalidConfiguration("unexpected fixture path")
        }
        return "let answer = 42\n"
    }

    func listFiles(workspaceID: UUID, path: String) async throws -> [String] {
        guard workspaceID == self.workspaceID, path.isEmpty else {
            throw AscendantBackendError.invalidConfiguration("unexpected fixture listing")
        }
        return ["Sources/example.swift"]
    }
}
#endif
