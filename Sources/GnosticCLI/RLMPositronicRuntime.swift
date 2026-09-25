// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticRLM
import GnosticRLMGuile
import GnosticRLMChibi
import GnosticRLMProcessWorker
import PKContracts
import PositronicKit

struct PositronicContributionModelAdapter: PositronicContributionModelService {
    let client: any LLMStreamClient

    func generate(prompt: String, tier: PositronicContributionModelTier) async throws -> String {
        let modelTier: ModelTier = switch tier {
        case .primary: .primary
        case .utility: .utility
        case .fast: .fast
        }
        let stream = await client.generationStream(
            messages: [LLMMessage(role: .user, content: prompt)],
            modelTier: modelTier
        )
        var result = ""
        for try await chunk in stream {
            result += chunk.choices.first?.delta.content ?? ""
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RLMFailure.rootModelFailed("the model returned an empty response")
        }
        return result
    }
}

private struct RLMRootModelAdapter: RLMRootModelClient {
    let model: any PositronicContributionModelService

    private static let maximumHistoryRecords = 16
    private static let maximumObservationCharacters = 2_048
    private static let maximumRepairRecords = 4

    func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep {
        let recentHistory = request.history.suffix(Self.maximumHistoryRecords)
        let omittedHistory = request.history.count - recentHistory.count
        let history = recentHistory.map { record in
            let observation = record.observation.textualDescription
            let boundedObservation = String(observation.prefix(Self.maximumObservationCharacters))
            let truncation = boundedObservation.count < observation.count ? "\n[observation truncated]" : ""
            return "operation=\(record.operation.textualDescription)\nobservation=\(boundedObservation)\(truncation)"
        }.joined(separator: "\n---\n")
        let historyHeader = omittedHistory > 0 ? "[\(omittedHistory) older observations omitted]\n" : ""
        let recentRepairs = request.repairs.suffix(Self.maximumRepairRecords)
        let repairs = recentRepairs
            .map { "iteration \($0.iteration): \($0.reason)" }
            .joined(separator: "\n")
        let prompt = """
        You are the root planner for a bounded recursive Workspace analysis.
        Return exactly one Scheme expression for the restricted RLM profile.
        Use only corpus-search, corpus-read, corpus-read-many, lm-query,
        lm-query-batched, progress, and finish. A finish expression must be
        the final host operation. Cite only chunk IDs returned by the corpus.

        Question: \(request.question)
        Snapshot: \(request.metadata.snapshotID)
        Files: \(request.metadata.fileCount), chunks: \(request.metadata.chunkCount)
        Allowed prefixes: \(request.metadata.allowedPathPrefixes.joined(separator: ", "))
        Remaining root iterations: \(request.remaining.rootIterations)
        Remaining leaf calls: \(request.remaining.leafModelCalls)
        History:
        \(historyHeader)\(history.isEmpty ? "(none)" : history)
        Previous cells that failed and must not be repeated:
        \(repairs.isEmpty ? "(none)" : repairs)
        """
        let response = try await model.generate(prompt: prompt, tier: .primary)
        let source = Self.schemeSource(response)
        guard !source.isEmpty else {
            return .invalid(reason: "root model returned no Scheme expression")
        }
        return .scheme(source: source)
    }

    private static func schemeSource(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = trimmed.range(of: "```") else { return trimmed }
        let bodyStart = trimmed[opening.upperBound...]
        let withoutLanguage: Substring
        if let newline = bodyStart.firstIndex(of: "\n") {
            withoutLanguage = bodyStart[bodyStart.index(after: newline)...]
        } else {
            withoutLanguage = bodyStart
        }
        guard let closing = withoutLanguage.range(of: "```") else {
            return String(withoutLanguage).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(withoutLanguage[..<closing.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RLMLeafModelAdapter: RLMLeafModelClient {
    let model: any PositronicContributionModelService

    private static let maximumConcurrentQueries = 8

    func query(prompts: [String], tier: RLMLeafModelTier) async throws -> [String] {
        let modelTier: PositronicContributionModelTier = switch tier {
        case .primary: .primary
        case .utility: .utility
        case .fast: .fast
        }
        var results: [(Int, String)] = []
        for start in stride(from: 0, to: prompts.count, by: Self.maximumConcurrentQueries) {
            let end = min(start + Self.maximumConcurrentQueries, prompts.count)
            let batch = try await withThrowingTaskGroup(of: (Int, String).self, returning: [(Int, String)].self) { group in
                for index in start..<end {
                    group.addTask {
                        (index, try await model.generate(prompt: prompts[index], tier: modelTier))
                    }
                }
                var batchResults: [(Int, String)] = []
                for try await result in group {
                    batchResults.append(result)
                }
                return batchResults
            }
            results.append(contentsOf: batch)
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

enum RLMWorkerSelection: String, Sendable, CaseIterable {
    case guile
    case chibi
}

enum RLMWorkerFactory {
    /// Resolves the worker script.
    ///
    /// An explicit environment override wins for development; otherwise the
    /// script bundled with the executor is used, so a deployed binary does not
    /// depend on its working directory.
    static func scriptPath(
        for selection: RLMWorkerSelection,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let environmentKey = selection == .guile ? "GNOSTIC_GUILE_WORKER" : "GNOSTIC_CHIBI_WORKER"
        if let path = environment[environmentKey], FileManager.default.fileExists(atPath: path) {
            return path
        }
        switch selection {
        case .guile: return RLMGuileWorkerConfiguration.defaultWorkerScriptPath
        case .chibi: return RLMChibiWorkerConfiguration.defaultWorkerScriptPath
        }
    }

    static func make(
        selection: RLMWorkerSelection,
        runID: String,
        host: RLMWorkerHostState
    ) throws -> any RLMWorkerDriver {
        guard let scriptPath = scriptPath(for: selection) else {
            throw RLMFailure.evaluatorFailed("selected Scheme worker script is unavailable")
        }
        switch selection {
        case .guile:
            let configuration = RLMGuileWorkerConfiguration(runID: runID, workerScriptPath: scriptPath)
            return RLMProcessWorkerDriver<RLMGuileExecutor>(
                configuration: configuration,
                host: RLMGuileClosureHost(handler: { operation in try await host.service(operation) }),
                wallTimeLimit: .milliseconds(Int64(configuration.wallDeadlineSeconds * 1_000)),
                outputLimitBytes: configuration.maxOutputBytes
            )
        case .chibi:
            #if os(Linux)
            let configuration = RLMChibiWorkerConfiguration(runID: runID, workerScriptPath: scriptPath)
            return RLMProcessWorkerDriver<RLMChibiExecutor>(
                configuration: configuration,
                host: RLMChibiClosureHost(handler: { operation in try await host.service(operation) }),
                wallTimeLimit: .milliseconds(Int64(configuration.wallDeadlineSeconds * 1_000)),
                outputLimitBytes: configuration.maxOutputBytes
            )
            #else
            throw RLMFailure.evaluatorFailed("Chibi worker is unavailable on this platform")
            #endif
        }
    }
}

struct RLMRunAssembly {
    let engine: RLMAnalysisEngine
    let evaluator: RLMWorkerCellEvaluator
}

enum RLMRunAssemblyFactory {
    /// - Parameter leafService: A separate service for leaf queries. The tool
    ///   uses one service for both roles; the #354 experiment passes two so it
    ///   can meter root and leaf calls apart.
    static func make(
        model: any PositronicContributionModelService,
        leafService: (any PositronicContributionModelService)? = nil,
        worker: RLMWorkerSelection,
        budget: RLMRunBudget,
        policy: RLMCorpusPolicy,
        progressSink: (any RLMProgressSink)?
    ) throws -> RLMRunAssembly {
        let leafModel = RLMLeafModelAdapter(model: leafService ?? model)
        let host = RLMWorkerHostState(
            leafModel: leafModel,
            budget: budget,
            tokenEstimator: RLMCharacterTokenEstimator(),
            progressSink: progressSink
        )
        let driver = try RLMWorkerFactory.make(selection: worker, runID: UUID().uuidString, host: host)
        let evaluator = RLMWorkerCellEvaluator(driver: driver, host: host)
        let engine = RLMAnalysisEngine(
            budget: budget,
            policy: policy,
            rootModel: RLMRootModelAdapter(model: model),
            leafModel: leafModel,
            evaluator: evaluator,
            progressSink: progressSink
        )
        return RLMRunAssembly(engine: engine, evaluator: evaluator)
    }
}
