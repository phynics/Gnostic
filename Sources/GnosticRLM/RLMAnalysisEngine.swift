// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The terminal outcome and metrics of one RLM run.
public struct RLMRunResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case completed(answer: String, evidence: [RLMEvidenceReference])
        case failed(RLMFailure)
        case cancelled
        case fenced
    }

    public let outcome: Outcome
    public let metrics: RLMRunMetrics
    public let snapshotID: String

    public init(outcome: Outcome, metrics: RLMRunMetrics, snapshotID: String) {
        self.outcome = outcome
        self.metrics = metrics
        self.snapshotID = snapshotID
    }
}

/// Drives the pure root loop with the host-owned clients and limits.
///
/// The engine owns snapshot capture, operation servicing, cancellation checks,
/// and the run generation fence. It performs no filesystem or network action of
/// its own: the corpus source, root model, and leaf model are injected.
public struct RLMAnalysisEngine: Sendable {
    public let budget: RLMRunBudget
    public let policy: RLMCorpusPolicy
    public let clock: any RLMClock
    public let tokenEstimator: any RLMTokenEstimator

    private let rootModel: any RLMRootModelClient
    private let leafModel: any RLMLeafModelClient
    private let evaluator: any RLMCellEvaluator
    private let progressSink: (any RLMProgressSink)?
    private let fence: RLMRunFence
    private let cancellation: RLMCancellationToken

    public init(
        budget: RLMRunBudget,
        policy: RLMCorpusPolicy = .standard,
        clock: any RLMClock = RLMSystemClock(),
        tokenEstimator: any RLMTokenEstimator = RLMCharacterTokenEstimator(),
        rootModel: any RLMRootModelClient,
        leafModel: any RLMLeafModelClient,
        evaluator: any RLMCellEvaluator = ScriptedCellEvaluator(),
        progressSink: (any RLMProgressSink)? = nil,
        fence: RLMRunFence = RLMRunFence(),
        cancellation: RLMCancellationToken = RLMCancellationToken()
    ) {
        self.budget = budget
        self.policy = policy
        self.clock = clock
        self.tokenEstimator = tokenEstimator
        self.rootModel = rootModel
        self.leafModel = leafModel
        self.evaluator = evaluator
        self.progressSink = progressSink
        self.fence = fence
        self.cancellation = cancellation
    }

    /// Captures the snapshot, runs the loop, and returns one terminal result.
    public func run(
        question: String,
        workspaceID: String,
        source: any RLMCorpusSource
    ) async -> RLMRunResult {
        let snapshot: RLMCorpusSnapshot
        do {
            snapshot = try await RLMCorpusSnapshotter(policy: policy).capture(
                from: source,
                workspaceID: workspaceID,
                budget: budget
            )
        } catch let failure as RLMFailure {
            return RLMRunResult(outcome: .failed(failure), metrics: .unavailable(), snapshotID: "unavailable")
        } catch {
            return RLMRunResult(
                outcome: .failed(.corpusSourceFailed(String(describing: error))),
                metrics: .unavailable(),
                snapshotID: "unavailable"
            )
        }

        if let evaluator = evaluator as? any RLMSnapshotAwareEvaluator {
            await evaluator.bind(snapshot: snapshot)
        }

        let generation = fence.current
        var loop = RLMRootLoop(
            question: question,
            snapshot: snapshot,
            budget: budget,
            tokenEstimator: tokenEstimator,
            clock: clock
        )
        var directive = loop.start()

        while true {
            if isCancelled() {
                _ = loop.cancel()
                return result(from: loop.termination, metrics: loop.runMetrics, snapshotID: snapshot.id, cancelled: true)
            }
            if !fence.accepts(generation) {
                return RLMRunResult(outcome: .fenced, metrics: loop.runMetrics, snapshotID: snapshot.id)
            }

            switch directive {
            case let .requestRootCell(request):
                do {
                    let step = try await rootModel.nextCell(request: request)
                    if let interruption = acceptContinuation(generation: generation, loop: &loop, snapshotID: snapshot.id) {
                        return interruption
                    }
                    directive = loop.receiveRootStep(step)
                } catch is CancellationError {
                    _ = loop.cancel()
                    return result(from: loop.termination, metrics: loop.runMetrics, snapshotID: snapshot.id, cancelled: true)
                } catch let failure as RLMFailure {
                    directive = loop.fail(failure)
                } catch {
                    directive = loop.fail(.rootModelFailed(String(describing: error)))
                }

            case let .scheduleCell(cell):
                do {
                    let operations = try await evaluator.schedule(cell)
                    if let fenced = acceptContinuation(generation: generation, loop: &loop, snapshotID: snapshot.id) {
                        return fenced
                    }
                    directive = loop.receiveScheduledOperations(operations)
                } catch is CancellationError {
                    _ = loop.cancel()
                    return result(from: loop.termination, metrics: loop.runMetrics, snapshotID: snapshot.id, cancelled: true)
                } catch let failure as RLMFailure {
                    directive = loop.fail(failure)
                } catch {
                    directive = loop.fail(.evaluatorFailed(String(describing: error)))
                }

            case let .scheduleScheme(source):
                do {
                    guard let evaluator = evaluator as? any RLMSchemeCellEvaluator else {
                        directive = loop.fail(.evaluatorFailed("no Scheme cell evaluator is installed"))
                        continue
                    }
                    let operations = try await evaluator.scheduleScheme(source)
                    if let fenced = acceptContinuation(generation: generation, loop: &loop, snapshotID: snapshot.id) {
                        return fenced
                    }
                    directive = loop.receiveScheduledOperations(operations)
                } catch is CancellationError {
                    _ = loop.cancel()
                    return result(from: loop.termination, metrics: loop.runMetrics, snapshotID: snapshot.id, cancelled: true)
                } catch let failure as RLMFailure {
                    directive = loop.fail(failure)
                } catch {
                    directive = loop.fail(.evaluatorFailed(String(describing: error)))
                }

            case let .service(operation):
                do {
                    let observation: RLMHostObservation
                    if let provider = evaluator as? any RLMRecordedObservationProvider,
                       let recorded = await provider.recordedObservation(for: operation) {
                        observation = recorded
                    } else {
                        observation = try await service(operation, snapshot: snapshot)
                    }
                    if let fenced = acceptContinuation(generation: generation, loop: &loop, snapshotID: snapshot.id) {
                        return fenced
                    }
                    directive = loop.receiveObservation(observation)
                } catch is CancellationError {
                    _ = loop.cancel()
                    return result(from: loop.termination, metrics: loop.runMetrics, snapshotID: snapshot.id, cancelled: true)
                } catch let failure as RLMFailure {
                    directive = loop.fail(failure)
                } catch {
                    directive = loop.fail(.evaluatorFailed(String(describing: error)))
                }

            case let .completed(answer, evidence):
                return RLMRunResult(
                    outcome: .completed(answer: answer, evidence: evidence),
                    metrics: loop.runMetrics,
                    snapshotID: snapshot.id
                )

            case let .failed(failure):
                return RLMRunResult(outcome: .failed(failure), metrics: loop.runMetrics, snapshotID: snapshot.id)

            case .cancelled:
                return result(from: loop.termination, metrics: loop.runMetrics, snapshotID: snapshot.id, cancelled: true)

            case .lateResultFenced:
                return RLMRunResult(outcome: .fenced, metrics: loop.runMetrics, snapshotID: snapshot.id)
            }
        }
    }

    private func isCancelled() -> Bool {
        cancellation.isCancelled || Task.isCancelled
    }

    private func acceptContinuation(
        generation: UInt64,
        loop: inout RLMRootLoop,
        snapshotID: String
    ) -> RLMRunResult? {
        if isCancelled() {
            _ = loop.cancel()
            return result(from: loop.termination, metrics: loop.runMetrics, snapshotID: snapshotID, cancelled: true)
        }
        if !fence.accepts(generation) {
            return RLMRunResult(outcome: .fenced, metrics: loop.runMetrics, snapshotID: snapshotID)
        }
        return nil
    }

    private func result(
        from termination: RLMRootLoop.Termination?,
        metrics: RLMRunMetrics,
        snapshotID: String,
        cancelled: Bool
    ) -> RLMRunResult {
        if cancelled {
            return RLMRunResult(outcome: .cancelled, metrics: metrics, snapshotID: snapshotID)
        }
        switch termination {
        case let .completed(answer, evidence):
            return RLMRunResult(outcome: .completed(answer: answer, evidence: evidence), metrics: metrics, snapshotID: snapshotID)
        case let .failed(failure):
            return RLMRunResult(outcome: .failed(failure), metrics: metrics, snapshotID: snapshotID)
        case .cancelled:
            return RLMRunResult(outcome: .cancelled, metrics: metrics, snapshotID: snapshotID)
        case nil:
            return RLMRunResult(outcome: .fenced, metrics: metrics, snapshotID: snapshotID)
        }
    }

    private func service(
        _ operation: RLMHostOperation,
        snapshot: RLMCorpusSnapshot
    ) async throws -> RLMHostObservation {
        switch operation {
        case let .corpusSearch(query, limit):
            let hits = RLMCorpusSearch.search(
                snapshot: snapshot,
                query: query,
                limit: min(max(limit, 0), budget.maxSearchLimit)
            )
            let bytesRead = hits.reduce(0) { $0 + $1.preview.utf8.count }
            return .corpusSearch(hits: hits, bytesRead: bytesRead)

        case let .corpusRead(chunkIDs):
            let limited = Array(chunkIDs.prefix(budget.maxChunksPerRead))
            let chunks = snapshot.chunks(ids: limited)
            let bytesRead = chunks.reduce(0) { $0 + $1.byteCount }
            return .corpusRead(chunks: chunks, bytesRead: bytesRead)

        case let .leafQuery(prompts, tier):
            let responses = try await leafModel.query(prompts: prompts, tier: tier)
            let estimatedTokens = responses.reduce(0) { $0 + tokenEstimator.estimateTokens(for: $1) }
            return .leaf(responses: responses, estimatedTokens: estimatedTokens)

        case let .progress(message):
            await progressSink?.report(message)
            return .progress

        case .finish:
            throw RLMFailure.evaluatorFailed("finish must not be serviced as a host operation")
        }
    }
}
