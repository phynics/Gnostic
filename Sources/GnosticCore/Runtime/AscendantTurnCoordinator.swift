// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Serializes and deduplicates stateful Ascendant Timeline turns for one serve
/// lifetime. A caller may disappear after admission; the coordinator-owned task
/// remains the single owner of the model/tool loop and its terminal outcome.
public actor AscendantTurnCoordinator {
    public typealias TurnOperation = @Sendable () async throws -> String

    private struct Key: Hashable, Sendable {
        let timelineID: UUID
        let clientTurnID: String
    }

    private struct InFlight: Sendable {
        let messageDigest: UInt64
        let operationID: String
        let ascendantID: UUID
        let task: Task<String, Error>
    }

    private struct AdmittedIdentity: Sendable {
        let messageDigest: UInt64
        let operationID: String
    }

    private struct Completed: Sendable {
        let messageDigest: UInt64
        let outcome: CachedOutcome
    }

    private struct Lane: Sendable {
        let id: UUID
        let task: Task<String, Error>
        let tail: Task<Void, Never>
    }

    private enum CachedOutcome: Sendable {
        case succeeded(AscendantTurnResult)
        case failed(AscendantTurnError)
    }

    private let completedCapacity: Int
    private let identityCapacity: Int
    private let observers: [any TerminalTurnObserving]
    private let observationScope: RuntimeEffectScope
    /// Every admitted identified turn remains in this ledger until serve
    /// shutdown. A missing key therefore means that admission never occurred.
    private var identities: [Key: AdmittedIdentity] = [:]
    private var inFlight: [Key: InFlight] = [:]
    private var completed: [Key: Completed] = [:]
    private var tombstones: [Key: UInt64] = [:]
    private var completionOrder: [Key] = []
    private var timelineTails: [UUID: Lane] = [:]
    private var acceptingTurns = true
    /// Set when shutdown begins. Observer deliveries scheduled after this
    /// point run inline in the settling Turn task instead of the disposed
    /// scope, so late real outcomes are still observed exactly once.
    private var observationClosed = false
    private var observationPending = 0
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []

    internal var retainedStateCounts: (identities: Int, completed: Int, tombstones: Int, completedBytes: Int) {
        (
            identities.count,
            completed.count,
            tombstones.count,
            completed.values.reduce(0) { $0 + Self.retainedPayloadBytes($1.outcome) }
        )
    }

    internal var retainedIdentityCount: Int { identities.count }

    internal var retainedTimelineCount: Int { timelineTails.count }

    internal var inFlightCount: Int { inFlight.count }

    internal func observationSnapshot() async -> RuntimeEffectSnapshot {
        await observationScope.snapshot()
    }

    /// - Parameters:
    ///   - completedCapacity: Maximum number of terminal outcomes kept for replay.
    ///   - identityCapacity: Maximum number of identified turns admitted during
    ///     this serve lifetime. Admitted identities are never evicted.
    public init(
        completedCapacity: Int = 256,
        identityCapacity: Int = 1_024,
        observers: [any TerminalTurnObserving] = []
    ) {
        self.completedCapacity = max(1, completedCapacity)
        self.identityCapacity = max(1, identityCapacity)
        self.observers = observers
        // This static label is validated by RuntimeEffectScope at construction.
        self.observationScope = try! RuntimeEffectScope(name: "turn-observation")
    }

    /// Cancels admitted work during node shutdown. New requests are rejected by
    /// the owning NodeRuntime before reaching this coordinator. Only real
    /// Turn-task completions terminalize a Turn: shutdown never fabricates an
    /// outcome, so a backend that ignores cancellation still commits and
    /// observes its real result. The bounded `false` path does not await
    /// noncooperative Turn or lane tasks, but it always drains already-committed
    /// observer deliveries before disposing the scope; `true` additionally
    /// awaits Turn and lane settlement.
    public func cancelAll(waitForCompletion: Bool = true) async {
        acceptingTurns = false
        let turns = inFlight.values.map(\.task) + timelineTails.values.map(\.task)
        let tails = timelineTails.values.map(\.tail)
        turns.forEach { $0.cancel() }
        tails.forEach { $0.cancel() }

        if waitForCompletion {
            for turn in turns { _ = await turn.result }
            for tail in tails { await tail.value }
        }
        // Close scope admission before draining: deliveries scheduled after
        // this point run inline in their settling Turn task. Draining first
        // guarantees dispose never cancels a live observer delivery.
        observationClosed = true
        while observationPending > 0 {
            await withCheckedContinuation { continuation in
                observationWaiters.append(continuation)
            }
        }
        _ = await observationScope.dispose()
    }

    /// Admits one turn. Requests without a client id use the compatibility path
    /// and are intentionally not deduplicated, while identified requests share
    /// one task per `(timelineID, clientTurnID)` key.
    public func execute(
        _ request: AscendantTurnRequest,
        ascendantID: UUID,
        operation: @escaping TurnOperation
    ) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        guard acceptingTurns else {
            throw AscendantTurnError.backendUnavailable(
                timelineID: request.timelineID,
                clientTurnID: request.clientTurnID ?? "",
                detail: "The Ascendant turn coordinator is shutting down."
            )
        }
        let operationID = Self.makeOperationID()
        guard let rawClientTurnID = request.clientTurnID else {
            let lane = enqueue(timelineID: request.timelineID, operation: operation, completion: { [weak self] result in
                await self?.recordCompletion(
                    key: nil,
                    request: request,
                    ascendantID: ascendantID,
                    operationID: operationID,
                    result: result
                )
            })
            do {
                let text = try await lane.task.value
                removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
                return AscendantTurnResult(clientTurnID: UUID().uuidString.lowercased(), text: text)
            } catch {
                removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
                throw error
            }
        }
        let clientTurnID = try GnosticWirePayload.canonicalClientTurnID(rawClientTurnID)
        let canonicalRequest = AscendantTurnRequest(
            message: request.message,
            timelineID: request.timelineID,
            clientTurnID: clientTurnID,
            protocolMajor: request.protocolMajor
        )

        let key = Key(timelineID: request.timelineID, clientTurnID: clientTurnID)
        let messageDigest = Self.messageDigest(request.message)
        let admittedIdentity: AdmittedIdentity
        if let existing = identities[key] {
            guard existing.messageDigest == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            admittedIdentity = existing
        } else {
            guard identities.count < identityCapacity else {
                throw AscendantTurnError.capacityExceeded(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID
                )
            }
            // Record identity before creating the operation. This admission is
            // permanent for the serve lifetime, even if its result is evicted.
            let identity = AdmittedIdentity(messageDigest: messageDigest, operationID: operationID)
            identities[key] = identity
            admittedIdentity = identity
        }

        if let existing = inFlight[key] {
            return try await replay(existing.task, request: canonicalRequest)
        }

        if let cached = completed[key] {
            guard cached.messageDigest == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            switch cached.outcome {
            case let .succeeded(result):
                return AscendantTurnResult(clientTurnID: result.clientTurnID, text: result.text, replayed: true)
            case let .failed(error):
                throw error
            }
        }

        if let tombstone = tombstones[key] {
            guard tombstone == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            throw AscendantTurnError.replayUnavailable(
                timelineID: request.timelineID,
                clientTurnID: clientTurnID
            )
        }

        let lane = enqueue(
            timelineID: request.timelineID,
            operation: {
                do {
                    return try await operation()
                } catch is CancellationError {
                    throw AscendantTurnError.cancelled(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID
                    )
                } catch let error as AscendantBackendError {
                    if case .cancelled = error {
                        throw AscendantTurnError.cancelled(
                            timelineID: request.timelineID,
                            clientTurnID: clientTurnID
                        )
                    }
                    if case let .lifecycleUnusable(failure) = error {
                        throw AscendantTurnError.lifecycleUnusable(
                            timelineID: request.timelineID,
                            clientTurnID: clientTurnID,
                            detail: failure.message
                        )
                    }
                    if case let .terminal(failure) = error {
                        throw AscendantTurnError.terminal(
                            timelineID: request.timelineID,
                            clientTurnID: clientTurnID,
                            code: failure.code,
                            detail: failure.message,
                            retryable: failure.retryable,
                            statusCode: 500
                        )
                    }
                    throw AscendantTurnError.terminal(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID,
                        code: error.reasonCode,
                        detail: error.localizedDescription,
                        retryable: false,
                        statusCode: error.statusCode
                    )
                } catch let error as AscendantTurnError {
                    throw error
                } catch {
                    throw AscendantTurnError.failed(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID,
                        detail: String(describing: error)
                    )
                }
            },
            completion: { [weak self] result in
                await self?.recordCompletion(
                    key: key,
                    request: canonicalRequest,
                    ascendantID: ascendantID,
                    operationID: admittedIdentity.operationID,
                    result: result
                )
            }
        )

        let task = lane.task
        inFlight[key] = InFlight(
            messageDigest: messageDigest,
            operationID: admittedIdentity.operationID,
            ascendantID: ascendantID,
            task: task
        )

        do {
            let text = try await task.value
            removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
            return AscendantTurnResult(clientTurnID: clientTurnID, text: text, replayed: false)
        } catch {
            removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
            throw error
        }
    }

    private func replay(
        _ task: Task<String, Error>,
        request: AscendantTurnRequest
    ) async throws -> AscendantTurnResult {
        do {
            let text = try await task.value
            return AscendantTurnResult(clientTurnID: request.clientTurnID, text: text, replayed: true)
        } catch {
            throw error
        }
    }

    private func recordCompletion(
        key: Key?,
        request: AscendantTurnRequest,
        ascendantID: UUID,
        operationID: String,
        result: Result<String, Error>
    ) async {
        var committedOperationID = operationID
        if let key {
            guard let admitted = inFlight.removeValue(forKey: key) else { return }
            committedOperationID = admitted.operationID
        }
        let digest = Self.messageDigest(request.message)

        let outcome: CachedOutcome
        let terminalOutcome: TerminalTurnOutcome
        switch result {
        case let .success(text):
            outcome = .succeeded(AscendantTurnResult(
                clientTurnID: request.clientTurnID,
                text: text,
                replayed: false
            ))
            terminalOutcome = .succeeded
        case let .failure(error):
            let terminal: AscendantTurnError
            if let error = error as? AscendantTurnError {
                terminal = error
            } else if error is CancellationError {
                terminal = .cancelled(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID ?? ""
                )
            } else {
                terminal = .failed(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID ?? "",
                    detail: String(describing: error)
                )
            }
            outcome = .failed(Self.bounded(terminal))
            terminalOutcome = Self.observationOutcome(for: terminal)
        }

        if let key {
            completed[key] = Completed(messageDigest: digest, outcome: outcome)
            completionOrder.removeAll { $0 == key }
            completionOrder.append(key)
            while completionOrder.count > completedCapacity {
                let oldest = completionOrder.removeFirst()
                guard let evicted = completed.removeValue(forKey: oldest) else { continue }
                // The identity ledger prevents rerun. Retain only the digest for an
                // evicted result so retries can still conflict or report 410.
                tombstones[oldest] = evicted.messageDigest
            }
        }

        await scheduleObservation(TerminalTurnRecord(
            operationID: committedOperationID,
            ascendantID: ascendantID,
            timelineID: request.timelineID,
            clientTurnID: request.clientTurnID,
            outcome: terminalOutcome
        ))
    }

    private func scheduleObservation(_ record: TerminalTurnRecord) async {
        guard !observers.isEmpty else { return }
        // After shutdown closes scope admission, deliver inline in the
        // settling Turn task: no new scope work may be admitted, but the
        // record must still reach observers exactly once.
        guard !observationClosed else {
            await deliverObservation(record)
            return
        }
        observationPending += 1
        do {
            // The closure holds the coordinator until delivery finishes;
            // the task releases it on completion, so ownership stays bounded.
            _ = try await observationScope.task(label: "turn-observation") {
                await self.deliverObservation(record)
                await self.completeObservation()
            }
        } catch {
            // The scope closed concurrently with shutdown; fall back to
            // inline delivery so the committed record is not dropped.
            await deliverObservation(record)
            completeObservation()
        }
    }

    private func deliverObservation(_ record: TerminalTurnRecord) async {
        for observer in observers {
            do {
                try await observer.observe(record)
            } catch {
                // Observers are diagnostics/side effects; they never
                // replace a committed client outcome or backend state.
            }
        }
    }

    private func completeObservation() {
        observationPending -= 1
        guard observationPending == 0 else { return }
        let waiters = observationWaiters
        observationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private static func observationOutcome(for error: AscendantTurnError) -> TerminalTurnOutcome {
        if case .cancelled = error { return .cancelled }
        return .failed(TerminalTurnFailure(
            reasonCode: error.reasonCode,
            statusCode: error.statusCode,
            retryable: error.retryable
        ))
    }

    private static func makeOperationID() -> String {
        UUID().uuidString.lowercased()
    }

    private static let retainedPayloadByteLimit = GnosticWirePayload.maximumEmbeddedValueBytes

    private static func bounded(_ error: AscendantTurnError) -> AscendantTurnError {
        switch error {
        case let .capacityExceeded(timelineID, clientTurnID):
            return .capacityExceeded(timelineID: timelineID, clientTurnID: clientTurnID)
        case let .conflict(timelineID, clientTurnID):
            return .conflict(timelineID: timelineID, clientTurnID: clientTurnID)
        case let .failed(timelineID, clientTurnID, detail):
            return .failed(timelineID: timelineID, clientTurnID: clientTurnID, detail: GnosticWirePayload.prefix(detail, maximumBytes: 1_200))
        case let .terminal(timelineID, clientTurnID, code, detail, retryable, statusCode):
            return .terminal(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                code: GnosticWirePayload.boundedIdentifier(code),
                detail: GnosticWirePayload.prefix(detail, maximumBytes: 1_200),
                retryable: retryable,
                statusCode: statusCode
            )
        case let .cancelled(timelineID, clientTurnID):
            return .cancelled(timelineID: timelineID, clientTurnID: clientTurnID)
        case let .lifecycleUnusable(timelineID, clientTurnID, detail):
            return .lifecycleUnusable(timelineID: timelineID, clientTurnID: clientTurnID, detail: GnosticWirePayload.prefix(detail, maximumBytes: 1_200))
        case let .backendUnavailable(timelineID, clientTurnID, detail):
            return .backendUnavailable(timelineID: timelineID, clientTurnID: clientTurnID, detail: GnosticWirePayload.prefix(detail, maximumBytes: 1_200))
        case let .replayUnavailable(timelineID, clientTurnID):
            return .replayUnavailable(timelineID: timelineID, clientTurnID: clientTurnID)
        }
    }

    private static func retainedPayloadBytes(_ outcome: CachedOutcome) -> Int {
        switch outcome {
        case let .succeeded(result):
            return (try? JSONEncoder().encode(result).count) ?? retainedPayloadByteLimit
        case let .failed(error):
            // The fields are bounded above, and this mirrors the wire fields
            // retained for conflict/status replay without retaining source text.
            return error.reasonCode.utf8.count + error.localizedDescription.utf8.count + 64
        }
    }

    /// A stable, process-local FNV-1a fingerprint keeps the coordinator's
    /// conflict record bounded without retaining the full user message.
    private static func messageDigest(_ message: String) -> UInt64 {
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in message.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return digest
    }

    private func enqueue(
        timelineID: UUID,
        operation: @escaping TurnOperation,
        completion: @escaping @Sendable (Result<String, Error>) async -> Void
    ) -> Lane {
        let predecessor = timelineTails[timelineID]?.tail
        let task = Task<String, Error> {
            do {
                _ = await predecessor?.value
                try Task.checkCancellation()
                let result = try await operation()
                await completion(.success(result))
                return result
            } catch {
                await completion(.failure(error))
                throw error
            }
        }
        let laneID = UUID()
        let tail = Task { [weak self] in
            _ = await task.result
            await self?.removeTimelineTail(timelineID: timelineID, laneID: laneID)
        }
        let lane = Lane(id: laneID, task: task, tail: tail)
        timelineTails[timelineID] = lane
        return lane
    }

    private func removeTimelineTail(timelineID: UUID, laneID: UUID) {
        guard timelineTails[timelineID]?.id == laneID else { return }
        timelineTails.removeValue(forKey: timelineID)
    }
}
