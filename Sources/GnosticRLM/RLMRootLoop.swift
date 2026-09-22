// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The next effect the harness must perform, or its terminal outcome.
public enum RLMLoopDirective: Sendable, Equatable {
    case requestRootCell(RLMRootRequest)
    case scheduleCell(RLMScriptedCell)
    case scheduleScheme(source: String)
    case service(RLMHostOperation)
    case completed(answer: String, evidence: [RLMEvidenceReference])
    case failed(RLMFailure)
    case cancelled
    case lateResultFenced
}

/// The continuation-driven root-loop state machine for one RLM run.
///
/// The loop is pure: it never performs I/O. The engine feeds it root responses
/// and serviced observations and performs whatever directive it returns. All
/// budget consumption, evidence validation, and termination decisions happen
/// here, so the orchestration contract is deterministic without a Scheme or
/// model runtime.
public struct RLMRootLoop: Sendable {
    public enum Phase: Sendable, Equatable {
        case notStarted
        case awaitingRootCell
        case scheduling
        case evaluating
        case terminated
    }

    public enum Termination: Sendable, Equatable {
        case completed(answer: String, evidence: [RLMEvidenceReference])
        case failed(RLMFailure)
        case cancelled
    }

    private let question: String
    private let snapshot: RLMCorpusSnapshot
    private let budget: RLMRunBudget
    private let tokenEstimator: any RLMTokenEstimator
    private let clock: any RLMClock
    private let startedAt: Duration

    private var ledger: RLMRunBudgetLedger
    private var metrics: RLMRunMetrics
    private var history: [RLMObservationRecord] = []
    private var repairs: [RLMRepairRecord] = []
    private var iteration = 0
    private var pendingOperations: [RLMHostOperation] = []
    private var pendingIndex = 0

    public private(set) var phase: Phase = .notStarted
    public private(set) var termination: Termination?

    public init(
        question: String,
        snapshot: RLMCorpusSnapshot,
        budget: RLMRunBudget,
        tokenEstimator: any RLMTokenEstimator = RLMCharacterTokenEstimator(),
        clock: any RLMClock = RLMSystemClock()
    ) {
        self.question = question
        self.snapshot = snapshot
        self.budget = budget
        self.tokenEstimator = tokenEstimator
        self.clock = clock
        self.startedAt = clock.now()
        self.ledger = RLMRunBudgetLedger(budget: budget, startedAt: clock.now())
        self.metrics = RLMRunMetrics(snapshotID: snapshot.id)
        self.metrics.corpusFiles = snapshot.files.count
        self.metrics.corpusChunks = snapshot.chunks.count
        self.metrics.corpusBytes = snapshot.totalBytes
        self.metrics.skippedFiles = snapshot.skipped.count
    }

    public var runMetrics: RLMRunMetrics {
        metrics
    }

    public var isTerminated: Bool {
        phase == .terminated
    }

    public var remainingBudget: RLMRunBudgetRemaining {
        ledger.remaining
    }

    /// Starts the run and returns the first directive.
    public mutating func start() -> RLMLoopDirective {
        switch phase {
        case .notStarted, .awaitingRootCell:
            return requestNextRootCell()
        case .scheduling, .evaluating, .terminated:
            return .lateResultFenced
        }
    }

    /// Accepts one root-model response.
    public mutating func receiveRootStep(_ step: RLMRootModelStep) -> RLMLoopDirective {
        guard phase == .awaitingRootCell else { return .lateResultFenced }
        if let failure = wallFailure() { return terminate(.failed(failure)) }

        switch step {
        case let .invalid(reason):
            _ = reason
            metrics.rootCellRejections += 1
            return requestNextRootCell()
        case let .cell(cell):
            guard cell.estimatedByteCount <= budget.maxSchemeCellBytes else {
                metrics.rootCellRejections += 1
                return requestNextRootCell()
            }
            let tokens = tokenEstimator.estimateTokens(for: cell.textualDescription)
            do {
                try ledger.consumeEstimatedModelTokens(tokens)
            } catch let failure as RLMFailure {
                return terminate(.failed(failure))
            } catch {
                return terminate(.failed(.rootModelFailed(String(describing: error))))
            }
            metrics.estimatedModelTokens += tokens
            phase = .scheduling
            return .scheduleCell(cell)
        case let .scheme(source):
            guard !source.isEmpty, source.utf8.count <= budget.maxSchemeCellBytes else {
                metrics.rootCellRejections += 1
                return requestNextRootCell()
            }
            let tokens = tokenEstimator.estimateTokens(for: source)
            do {
                try ledger.consumeEstimatedModelTokens(tokens)
            } catch let failure as RLMFailure {
                return terminate(.failed(failure))
            } catch {
                return terminate(.failed(.rootModelFailed(String(describing: error))))
            }
            metrics.estimatedModelTokens += tokens
            phase = .scheduling
            return .scheduleScheme(source: source)
        }
    }

    /// Accepts the scheduled host operations for the current cell.
    public mutating func receiveScheduledOperations(_ operations: [RLMHostOperation]) -> RLMLoopDirective {
        guard phase == .scheduling else { return .lateResultFenced }
        pendingOperations = operations
        pendingIndex = 0
        phase = .evaluating
        return advanceEvaluation()
    }

    /// Feeds one recoverable cell failure back to the root model for repair.
    ///
    /// Only a recoverable cell failure earns a repair. Every other failure is
    /// terminal here, so fencing, cancellation, worker and protocol faults, and
    /// run-budget exhaustion keep the behaviour they had before repair existed.
    ///
    /// The root iteration containing the failed cell is already consumed. The
    /// next request therefore advances the same root iteration budget as any
    /// other continuation, and the repair budget bounds how many times a run may
    /// take that path at all.
    public mutating func rejectScheduledCell(_ failure: RLMFailure) -> RLMLoopDirective {
        guard phase == .scheduling else { return .lateResultFenced }
        guard failure.isRecoverableCellFailure else { return terminate(.failed(failure)) }

        switch failure {
        case .cellRejected:
            metrics.rootCellRejections += 1
        case .cellRuntimeFailed:
            metrics.runtimeFailures += 1
        default:
            break
        }

        guard metrics.repairs < budget.maxCellRepairs else {
            return terminate(.failed(failure))
        }
        metrics.repairs += 1
        if let reason = failure.repairDescription {
            repairs.append(RLMRepairRecord(iteration: iteration, reason: reason))
        }
        return requestNextRootCell()
    }

    /// Accepts the observation produced by servicing the current operation.
    public mutating func receiveObservation(_ observation: RLMHostObservation) -> RLMLoopDirective {
        guard phase == .evaluating, pendingIndex < pendingOperations.count else {
            return .lateResultFenced
        }
        let operation = pendingOperations[pendingIndex]
        guard matches(observation, operation) else {
            return terminate(.failed(.evaluatorFailed("observation does not match the scheduled operation")))
        }
        if let failure = wallFailure() { return terminate(.failed(failure)) }

        switch observation {
        case let .corpusSearch(_, bytesRead):
            do {
                try ledger.consumeContextRead(bytes: bytesRead)
            } catch let failure as RLMFailure {
                return terminate(.failed(failure))
            } catch {
                return terminate(.failed(.contextReadLimitReached(limit: budget.maxCorpusBytesRead)))
            }
            metrics.contextReadBytes += bytesRead
            metrics.corpusSearchCalls += 1
        case let .corpusRead(_, bytesRead):
            do {
                try ledger.consumeContextRead(bytes: bytesRead)
            } catch let failure as RLMFailure {
                return terminate(.failed(failure))
            } catch {
                return terminate(.failed(.contextReadLimitReached(limit: budget.maxCorpusBytesRead)))
            }
            metrics.contextReadBytes += bytesRead
            metrics.corpusReadCalls += 1
        case let .leaf(responses, estimatedTokens):
            do {
                try ledger.consumeEstimatedModelTokens(estimatedTokens)
            } catch let failure as RLMFailure {
                return terminate(.failed(failure))
            } catch {
                return terminate(.failed(.tokenLimitReached(limit: budget.maxEstimatedModelTokens)))
            }
            let outputBytes = responses.reduce(0) { $0 + $1.utf8.count }
            do {
                try ledger.consumeOutput(bytes: outputBytes)
            } catch let failure as RLMFailure {
                return terminate(.failed(failure))
            } catch {
                return terminate(.failed(.outputLimitReached(limit: budget.maxSchemeOutputBytes)))
            }
            metrics.estimatedModelTokens += estimatedTokens
            metrics.cellOutputBytes += outputBytes
        case .progress:
            break
        }

        let estimatedTokens = tokenEstimator.estimateTokens(for: observation.textualDescription)
        history.append(
            RLMObservationRecord(
                iteration: iteration,
                operation: operation,
                observation: observation,
                estimatedTokens: estimatedTokens
            )
        )
        pendingIndex += 1
        return advanceEvaluation()
    }

    /// Cancels the run. A second call is fenced.
    public mutating func cancel() -> RLMLoopDirective {
        guard phase != .terminated else { return .lateResultFenced }
        return terminate(.cancelled)
    }

    /// Terminates the run with a host failure.
    public mutating func fail(_ failure: RLMFailure) -> RLMLoopDirective {
        guard phase != .terminated else { return .lateResultFenced }
        return terminate(.failed(failure))
    }

    private mutating func requestNextRootCell() -> RLMLoopDirective {
        if let failure = wallFailure() { return terminate(.failed(failure)) }
        do {
            try ledger.consumeRootIteration()
        } catch let failure as RLMFailure {
            return terminate(.failed(failure))
        } catch {
            return terminate(.failed(.rootModelFailed(String(describing: error))))
        }
        iteration += 1
        metrics.rootIterations += 1
        phase = .awaitingRootCell
        return .requestRootCell(
            RLMRootRequest(
                question: question,
                metadata: snapshot.metadata,
                remaining: ledger.remaining,
                history: history,
                repairs: repairs
            )
        )
    }

    private mutating func advanceEvaluation() -> RLMLoopDirective {
        if let failure = wallFailure() { return terminate(.failed(failure)) }
        while pendingIndex < pendingOperations.count {
            let operation = pendingOperations[pendingIndex]
            switch operation {
            case let .finish(answer, evidence):
                return finish(answer: answer, evidence: evidence)
            case let .leafQuery(prompts, _):
                do {
                    try ledger.consumeLeafModelCalls(prompts.count)
                } catch let failure as RLMFailure {
                    return terminate(.failed(failure))
                } catch {
                    return terminate(.failed(.leafModelFailed(String(describing: error))))
                }
                metrics.leafModelCalls += 1
                metrics.leafPrompts += prompts.count
                return .service(operation)
            case .corpusSearch, .corpusRead, .progress:
                return .service(operation)
            }
        }
        pendingOperations = []
        pendingIndex = 0
        return requestNextRootCell()
    }

    private mutating func finish(answer: String, evidence: [RLMEvidenceReference]) -> RLMLoopDirective {
        let answerBytes = answer.utf8.count
        do {
            try ledger.consumeOutput(bytes: answerBytes)
        } catch let failure as RLMFailure {
            return terminate(.failed(failure))
        } catch {
            return terminate(.failed(.outputLimitReached(limit: budget.maxSchemeOutputBytes)))
        }
        metrics.cellOutputBytes += answerBytes

        let validated: [RLMEvidenceReference]
        do {
            validated = try RLMEvidenceValidator.validate(
                evidence,
                against: snapshot,
                limit: budget.maxEvidenceReferences
            )
        } catch let failure as RLMFailure {
            return terminate(.failed(failure))
        } catch {
            return terminate(.failed(.evidenceRejected(.tooManyReferences(limit: budget.maxEvidenceReferences))))
        }
        metrics.evidenceReferences = validated.count
        return terminate(.completed(answer: answer, evidence: validated))
    }

    private func matches(_ observation: RLMHostObservation, _ operation: RLMHostOperation) -> Bool {
        switch (observation, operation) {
        case (.corpusSearch, .corpusSearch):
            return true
        case (.corpusRead, .corpusRead):
            return true
        case (.leaf, .leafQuery):
            return true
        case (.progress, .progress):
            return true
        default:
            return false
        }
    }

    private func wallFailure() -> RLMFailure? {
        do {
            try ledger.checkWallTime(now: clock.now())
            return nil
        } catch let failure as RLMFailure {
            return failure
        } catch {
            return .wallTimeLimitReached(limit: budget.maxWallDuration)
        }
    }

    private mutating func terminate(_ termination: Termination) -> RLMLoopDirective {
        if phase == .terminated {
            return .lateResultFenced
        }
        phase = .terminated
        self.termination = termination
        metrics.wallDuration = clock.now() - startedAt
        switch termination {
        case let .completed(answer, evidence):
            return .completed(answer: answer, evidence: evidence)
        case let .failed(failure):
            return .failed(failure)
        case .cancelled:
            return .cancelled
        }
    }
}
