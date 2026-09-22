// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM

/// Adapts one `RLMProcessWorkerSession` to the harness `RLMWorkerDriver`
/// protocol.
///
/// The mapping from the shared worker outcome to a normalized
/// `RLMWorkerEvaluation` is executor-independent, so every runtime uses this one
/// driver. The executor contributes only its `displayName` for diagnostics.
public struct RLMProcessWorkerDriver<Executor: RLMWorkerExecutor>: RLMWorkerDriver {
    private let session: RLMProcessWorkerSession<Executor>
    private let wallTimeLimit: Duration
    private let outputLimitBytes: Int

    public init(
        configuration: Executor.Configuration,
        host: any RLMWorkerHost,
        wallTimeLimit: Duration,
        outputLimitBytes: Int,
        cancellation: RLMCancellationToken = RLMCancellationToken()
    ) {
        self.session = RLMProcessWorkerSession(
            configuration: configuration,
            host: host,
            cancellation: cancellation
        )
        self.wallTimeLimit = wallTimeLimit
        self.outputLimitBytes = outputLimitBytes
    }

    public func start() async throws { try await session.start() }

    public func evaluate(source: String) async -> RLMWorkerEvaluation {
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
        case let .workerExited(code): .failed(.evaluatorFailed("\(Executor.displayName) worker exited with status \(code)"))
        case let .protocolViolation(message): .failed(.evaluatorFailed(message))
        case .unsupportedPlatform: .unsupported
        }
    }

    public func cancel() async { await session.cancel() }
    public func shutdown() async { await session.shutdown() }

    /// The running worker process identifier, or `nil` when it is not running.
    /// Exposed for diagnostics and benchmark sampling.
    public var processIdentifier: Int32? {
        get async { await session.processIdentifier }
    }
}
