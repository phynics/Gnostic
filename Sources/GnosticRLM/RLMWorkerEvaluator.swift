// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The normalized outcome of one worker evaluation.
///
/// Every executor reports this vocabulary, so an evaluator, driver or test
/// built on it is independent of the Scheme runtime behind it.
public enum RLMWorkerEvaluation: Sendable {
    case value(RLMSExpression?)
    case finished(answer: String, evidenceIDs: [String])
    case failed(RLMFailure)
    case cancelled
    case fenced
    case unsupported
}

/// A started worker that evaluates one Scheme cell and reports a normalized
/// outcome.
///
/// The harness composes against this protocol, not against a concrete runtime
/// session, so one `RLMWorkerCellEvaluator` serves every executor.
public protocol RLMWorkerDriver: Sendable {
    func start() async throws
    func evaluate(source: String) async -> RLMWorkerEvaluation
    func cancel() async
    func shutdown() async
}

/// Maps a worker-reported Scheme failure message to the harness failure kind.
///
/// A bounded host call that failed, or an exhausted resource limit, is an
/// evaluator fault. Every other Scheme failure is a runtime fault in a
/// generated cell, which the root model may repair.
public enum RLMWorkerFailureClassifier {
    public static func classify(_ message: String) -> RLMFailure {
        if message.contains("host call failed") || message == "resource limit exceeded" {
            return .evaluatorFailed(message)
        }
        return .cellRuntimeFailed(message)
    }
}

/// Services the bounded host operations a running worker requests during one
/// cell.
public actor RLMWorkerHostState {
    private let leafModel: any RLMLeafModelClient
    private let tokenEstimator: any RLMTokenEstimator
    private let budget: RLMRunBudget
    private let progressSink: (any RLMProgressSink)?
    private var snapshot: RLMCorpusSnapshot?
    private var leafModelCalls = 0
    private var records: [(RLMHostOperation, RLMHostObservation)] = []

    public init(
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

    public func bind(snapshot: RLMCorpusSnapshot) {
        self.snapshot = snapshot
    }

    public func beginCell() {
        records.removeAll(keepingCapacity: true)
    }

    public func drainRecords() -> [(RLMHostOperation, RLMHostObservation)] {
        defer { records.removeAll(keepingCapacity: true) }
        return records
    }

    public func service(_ operation: RLMHostOperation) async throws -> RLMHostObservation {
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

/// Adapts any `RLMWorkerDriver` to the harness cell-evaluator protocols.
///
/// The evaluator is executor-independent: the driver supplies the runtime and
/// the host state supplies the bounded corpus and model operations.
public actor RLMWorkerCellEvaluator: RLMSchemeCellEvaluator, RLMRecordedObservationProvider, RLMSnapshotAwareEvaluator {
    private let driver: any RLMWorkerDriver
    private let host: RLMWorkerHostState
    private var snapshot: RLMCorpusSnapshot?
    private var pendingObservations: [(RLMHostOperation, RLMHostObservation)] = []

    public init(driver: any RLMWorkerDriver, host: RLMWorkerHostState) {
        self.driver = driver
        self.host = host
    }

    public func start() async throws { try await driver.start() }

    public func bind(snapshot: RLMCorpusSnapshot) async {
        self.snapshot = snapshot
        await host.bind(snapshot: snapshot)
    }

    public func schedule(_ cell: RLMScriptedCell) async throws -> [RLMHostOperation] {
        _ = cell
        throw RLMFailure.evaluatorFailed("the worker evaluator requires a Scheme cell")
    }

    public func scheduleScheme(_ source: String) async throws -> [RLMHostOperation] {
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

    public func recordedObservation(for operation: RLMHostOperation) async -> RLMHostObservation? {
        guard let index = pendingObservations.firstIndex(where: { $0.0 == operation }) else { return nil }
        return pendingObservations.remove(at: index).1
    }

    public func cancel() async { await driver.cancel() }
    public func shutdown() async { await driver.shutdown() }
}
