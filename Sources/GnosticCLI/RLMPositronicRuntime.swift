// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticRLM
import GnosticRLMGuile
import GnosticRLMChibi
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

enum RLMWorkerEvaluation: Sendable {
    case value(RLMSExpression?)
    case finished(answer: String, evidenceIDs: [String])
    case failed(RLMFailure)
    case cancelled
    case fenced
    case unsupported
}

protocol RLMWorkerDriver: Sendable {
    func start() async throws
    func evaluate(source: String) async -> RLMWorkerEvaluation
    func cancel() async
    func shutdown() async
}

struct GuileWorkerDriver: RLMWorkerDriver {
    let session: RLMGuileWorkerSession
    let wallTimeLimit: Duration
    let outputLimitBytes: Int

    func start() async throws { try await session.start() }

    func evaluate(source: String) async -> RLMWorkerEvaluation {
        switch await session.evaluate(source: source) {
        case let .value(value): .value(value)
        case let .finished(answer, evidenceIDs): .finished(answer: answer, evidenceIDs: evidenceIDs)
        case let .schemeFailed(message): .failed(RLMWorkerFailureClassifier.classify(message))
        case let .cellRejected(message): .failed(.cellRejected(message))
        case .timedOut: .failed(.wallTimeLimitReached(limit: wallTimeLimit))
        case .outputLimitReached: .failed(.outputLimitReached(limit: outputLimitBytes))
        case let .hostResultRejected(message): .failed(.evaluatorFailed(message))
        case .cancelled: .cancelled
        case .fenced: .fenced
        case let .workerExited(code): .failed(.evaluatorFailed("Guile worker exited with status \(code)"))
        case let .protocolViolation(message): .failed(.evaluatorFailed(message))
        case .unsupportedPlatform: .unsupported
        }
    }

    func cancel() async { await session.cancel() }
    func shutdown() async { await session.shutdown() }
}

#if os(Linux)
struct ChibiWorkerDriver: RLMWorkerDriver {
    let session: RLMChibiWorkerSession
    let wallTimeLimit: Duration
    let outputLimitBytes: Int

    func start() async throws { try await session.start() }

    func evaluate(source: String) async -> RLMWorkerEvaluation {
        switch await session.evaluate(source: source) {
        case let .value(value): .value(value)
        case let .finished(answer, evidenceIDs): .finished(answer: answer, evidenceIDs: evidenceIDs)
        case let .schemeFailed(message): .failed(RLMWorkerFailureClassifier.classify(message))
        case let .cellRejected(message): .failed(.cellRejected(message))
        case .timedOut: .failed(.wallTimeLimitReached(limit: wallTimeLimit))
        case .outputLimitReached: .failed(.outputLimitReached(limit: outputLimitBytes))
        case let .hostResultRejected(message): .failed(.evaluatorFailed(message))
        case .cancelled: .cancelled
        case .fenced: .fenced
        case let .workerExited(code): .failed(.evaluatorFailed("Chibi worker exited with status \(code)"))
        case let .protocolViolation(message): .failed(.evaluatorFailed(message))
        case .unsupportedPlatform: .unsupported
        }
    }

    func cancel() async { await session.cancel() }
    func shutdown() async { await session.shutdown() }
}
#endif

enum RLMWorkerFailureClassifier {
    static func classify(_ message: String) -> RLMFailure {
        if message.contains("host call failed") || message == "resource limit exceeded" {
            return .evaluatorFailed(message)
        }
        return .cellRuntimeFailed(message)
    }
}

actor RLMWorkerHostState {
    private let leafModel: any RLMLeafModelClient
    private let tokenEstimator: any RLMTokenEstimator
    private let budget: RLMRunBudget
    private let progressSink: (any RLMProgressSink)?
    private var snapshot: RLMCorpusSnapshot?
    private var leafModelCalls = 0
    private var records: [(RLMHostOperation, RLMHostObservation)] = []

    init(
        leafModel: any RLMLeafModelClient,
        budget: RLMRunBudget,
        tokenEstimator: any RLMTokenEstimator,
        progressSink: (any RLMProgressSink)?
    ) {
        self.leafModel = leafModel
        self.budget = budget
        self.tokenEstimator = tokenEstimator
        self.progressSink = progressSink
    }

    func bind(snapshot: RLMCorpusSnapshot) {
        self.snapshot = snapshot
    }

    func beginCell() {
        records.removeAll(keepingCapacity: true)
    }

    func drainRecords() -> [(RLMHostOperation, RLMHostObservation)] {
        defer { records.removeAll(keepingCapacity: true) }
        return records
    }

    func service(_ operation: RLMHostOperation) async throws -> RLMHostObservation {
        guard let snapshot else {
            throw RLMFailure.evaluatorFailed("worker host was used before snapshot binding")
        }
        let observation: RLMHostObservation
        switch operation {
        case let .corpusSearch(query, limit):
            let hits = RLMCorpusSearch.search(snapshot: snapshot, query: query, limit: min(max(limit, 0), budget.maxSearchLimit))
            observation = .corpusSearch(hits: hits, bytesRead: hits.reduce(0) { $0 + $1.preview.utf8.count })
        case let .corpusRead(chunkIDs):
            let chunks = snapshot.chunks(ids: Array(chunkIDs.prefix(budget.maxChunksPerRead)))
            observation = .corpusRead(chunks: chunks, bytesRead: chunks.reduce(0) { $0 + $1.byteCount })
        case let .leafQuery(prompts, tier):
            guard leafModelCalls + prompts.count <= budget.maxLeafModelCalls else {
                throw RLMFailure.leafCallLimitReached(limit: budget.maxLeafModelCalls)
            }
            leafModelCalls += prompts.count
            let responses = try await leafModel.query(prompts: prompts, tier: tier)
            observation = .leaf(
                responses: responses,
                estimatedTokens: responses.reduce(0) { $0 + tokenEstimator.estimateTokens(for: $1) }
            )
        case let .progress(message):
            await progressSink?.report(message)
            observation = .progress
        case .finish:
            throw RLMFailure.evaluatorFailed("finish must not be serviced by the worker host")
        }
        records.append((operation, observation))
        return observation
    }
}

actor RLMWorkerCellEvaluator: RLMSchemeCellEvaluator, RLMRecordedObservationProvider, RLMSnapshotAwareEvaluator {
    private let driver: any RLMWorkerDriver
    private let host: RLMWorkerHostState
    private var snapshot: RLMCorpusSnapshot?
    private var pendingObservations: [(RLMHostOperation, RLMHostObservation)] = []

    init(driver: any RLMWorkerDriver, host: RLMWorkerHostState) {
        self.driver = driver
        self.host = host
    }

    func start() async throws { try await driver.start() }

    func bind(snapshot: RLMCorpusSnapshot) async {
        self.snapshot = snapshot
        await host.bind(snapshot: snapshot)
    }

    func schedule(_ cell: RLMScriptedCell) async throws -> [RLMHostOperation] {
        _ = cell
        throw RLMFailure.evaluatorFailed("the worker evaluator requires a Scheme cell")
    }

    func scheduleScheme(_ source: String) async throws -> [RLMHostOperation] {
        await host.beginCell()
        let outcome = await driver.evaluate(source: source)
        switch outcome {
        case let .failed(failure): throw failure
        case .cancelled: throw RLMFailure.cancelled
        case .fenced: throw RLMFailure.lateResultFenced
        case .unsupported: throw RLMFailure.evaluatorFailed("selected Scheme worker is unsupported on this platform")
        case .value, .finished:
            let records = await host.drainRecords()
            pendingObservations.append(contentsOf: records)
            var operations = records.map(\.0)
            if case let .finished(answer, evidenceIDs) = outcome {
                guard let snapshot else {
                    throw RLMFailure.evaluatorFailed("worker finished before snapshot binding")
                }
                let evidence = try evidenceIDs.map { id -> RLMEvidenceReference in
                    guard let chunk = snapshot.chunk(id: id) else {
                        throw RLMFailure.evidenceRejected(.unknownChunk(id))
                    }
                    return RLMEvidenceReference(
                        chunkID: chunk.id,
                        path: chunk.path,
                        startLine: chunk.startLine,
                        endLine: chunk.endLine
                    )
                }
                operations.append(.finish(answer: answer, evidence: evidence))
            }
            return operations
        }
    }

    func recordedObservation(for operation: RLMHostOperation) async -> RLMHostObservation? {
        guard let index = pendingObservations.firstIndex(where: { $0.0 == operation }) else { return nil }
        return pendingObservations.remove(at: index).1
    }

    func cancel() async { await driver.cancel() }
    func shutdown() async { await driver.shutdown() }
}

enum RLMWorkerSelection: String, Sendable, CaseIterable {
    case guile
    case chibi
}

enum RLMWorkerFactory {
    static func scriptPath(for selection: RLMWorkerSelection) -> String? {
        let environmentKey = selection == .guile ? "GNOSTIC_GUILE_WORKER" : "GNOSTIC_CHIBI_WORKER"
        if let path = ProcessInfo.processInfo.environment[environmentKey], FileManager.default.fileExists(atPath: path) {
            return path
        }
        let relative = selection == .guile
            ? "Experiments/GuileRLMWorker/worker.scm"
            : "Experiments/ChibiRLMWorker/worker.scm"
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relative).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
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
            return GuileWorkerDriver(
                session: RLMGuileWorkerSession(
                configuration: configuration,
                host: RLMGuileClosureHost(handler: { operation in try await host.service(operation) })
                ),
                wallTimeLimit: .milliseconds(Int64(configuration.wallDeadlineSeconds * 1_000)),
                outputLimitBytes: configuration.maxOutputBytes
            )
        case .chibi:
            #if os(Linux)
            let configuration = RLMChibiWorkerConfiguration(runID: runID, workerScriptPath: scriptPath)
            return ChibiWorkerDriver(
                session: RLMChibiWorkerSession(
                configuration: configuration,
                host: RLMChibiClosureHost(handler: { operation in try await host.service(operation) })
                ),
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
    static func make(
        model: any PositronicContributionModelService,
        worker: RLMWorkerSelection,
        budget: RLMRunBudget,
        policy: RLMCorpusPolicy,
        progressSink: (any RLMProgressSink)?
    ) throws -> RLMRunAssembly {
        let leafModel = RLMLeafModelAdapter(model: model)
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
