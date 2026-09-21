// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A configured model tier that a leaf call may target.
public enum RLMLeafModelTier: String, Sendable, Equatable, CaseIterable {
    case primary
    case fast
    case utility
}

/// One host operation requested by a generated cell.
public enum RLMHostOperation: Sendable, Equatable {
    case corpusSearch(query: String, limit: Int)
    case corpusRead(chunkIDs: [String])
    case leafQuery(prompts: [String], tier: RLMLeafModelTier)
    case progress(String)
    case finish(answer: String, evidence: [RLMEvidenceReference])

    /// A deterministic, content-free size estimate for cell and token budgets.
    public var estimatedByteCount: Int {
        textualDescription.utf8.count
    }

    /// A deterministic textual projection used for token estimation and metrics.
    public var textualDescription: String {
        switch self {
        case let .corpusSearch(query, limit):
            return "corpus-search \(limit) \(query)"
        case let .corpusRead(chunkIDs):
            return "corpus-read \(chunkIDs.joined(separator: ","))"
        case let .leafQuery(prompts, tier):
            return "lm-query \(tier.rawValue) \(prompts.joined(separator: " | "))"
        case let .progress(message):
            return "progress \(message)"
        case let .finish(answer, evidence):
            let references = evidence.map { "\($0.chunkID)@\($0.startLine)-\($0.endLine)" }
            return "finish \(answer) \(references.joined(separator: ","))"
        }
    }
}

/// The result of servicing one host operation.
public enum RLMHostObservation: Sendable, Equatable {
    case corpusSearch(hits: [RLMSearchHit], bytesRead: Int)
    case corpusRead(chunks: [RLMCorpusChunk], bytesRead: Int)
    case leaf(responses: [String], estimatedTokens: Int)
    case progress

    /// A deterministic textual projection used for history and token estimation.
    public var textualDescription: String {
        switch self {
        case let .corpusSearch(hits, _):
            return hits.map { "\($0.chunkID) \($0.preview)" }.joined(separator: "\n")
        case let .corpusRead(chunks, _):
            return chunks.map(\.content).joined(separator: "\n")
        case let .leaf(responses, _):
            return responses.joined(separator: "\n")
        case .progress:
            return "progress"
        }
    }
}

/// One generated cell produced by a root model.
public struct RLMScriptedCell: Sendable, Equatable {
    public let operations: [RLMHostOperation]

    public init(_ operations: [RLMHostOperation]) {
        self.operations = operations
    }

    public init(operations: [RLMHostOperation]) {
        self.operations = operations
    }

    public var estimatedByteCount: Int {
        operations.reduce(0) { $0 + $1.estimatedByteCount }
    }

    public var textualDescription: String {
        operations.map(\.textualDescription).joined(separator: "\n")
    }
}

/// A root model response: either one cell or a signal that no valid cell exists.
public enum RLMRootModelStep: Sendable, Equatable {
    case cell(RLMScriptedCell)
    /// A validated-at-the-worker-boundary Scheme cell.
    case scheme(source: String)
    case invalid(reason: String)
}

/// One recorded cell operation and the observation it produced.
public struct RLMObservationRecord: Sendable, Equatable {
    public let iteration: Int
    public let operation: RLMHostOperation
    public let observation: RLMHostObservation
    public let estimatedTokens: Int

    public init(
        iteration: Int,
        operation: RLMHostOperation,
        observation: RLMHostObservation,
        estimatedTokens: Int
    ) {
        self.iteration = iteration
        self.operation = operation
        self.observation = observation
        self.estimatedTokens = estimatedTokens
    }
}

/// The bounded context handed to a root model on each iteration.
public struct RLMRootRequest: Sendable, Equatable {
    public let question: String
    public let metadata: RLMCorpusMetadata
    public let remaining: RLMRunBudgetRemaining
    public let history: [RLMObservationRecord]

    public init(
        question: String,
        metadata: RLMCorpusMetadata,
        remaining: RLMRunBudgetRemaining,
        history: [RLMObservationRecord]
    ) {
        self.question = question
        self.metadata = metadata
        self.remaining = remaining
        self.history = history
    }
}

/// A root model client. The harness owns prompting and budgets; the client owns
/// only generation.
public protocol RLMRootModelClient: Sendable {
    func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep
}

/// A leaf model client. Batched prompts consume one budget slot per prompt.
public protocol RLMLeafModelClient: Sendable {
    func query(prompts: [String], tier: RLMLeafModelTier) async throws -> [String]
}

/// Optional bounded progress reporting for a run.
public protocol RLMProgressSink: Sendable {
    func report(_ message: String) async
}

/// Produces the host operations for one generated cell.
///
/// This is the seam where a real Scheme worker is integrated. The Phase 0
/// evaluator is scripted, so orchestration is proven without an interpreter.
public protocol RLMCellEvaluator: Sendable {
    func schedule(_ cell: RLMScriptedCell) async throws -> [RLMHostOperation]
}

/// Evaluates a Scheme cell in a supervised worker process.
public protocol RLMSchemeCellEvaluator: RLMCellEvaluator {
    func scheduleScheme(_ source: String) async throws -> [RLMHostOperation]
}

/// Allows a worker-backed evaluator to hand observations already produced by
/// its host bridge back to the engine. This prevents corpus and leaf requests
/// from running a second time when the Scheme worker has already awaited them.
public protocol RLMRecordedObservationProvider: Sendable {
    func recordedObservation(for operation: RLMHostOperation) async -> RLMHostObservation?
}

/// Binds an evaluator to the immutable snapshot captured by the engine.
public protocol RLMSnapshotAwareEvaluator: Sendable {
    func bind(snapshot: RLMCorpusSnapshot) async
}

/// The Phase 0 evaluator: it replays the operations carried by the cell.
public struct ScriptedCellEvaluator: RLMCellEvaluator {
    public init() {}

    public func schedule(_ cell: RLMScriptedCell) async throws -> [RLMHostOperation] {
        cell.operations
    }
}
