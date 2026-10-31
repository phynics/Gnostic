// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// Admits and deduplicates stateful Ascendant Timeline turns for one serve
/// lifetime. A caller may disappear after admission; the coordinator-owned task
/// remains the single owner of the model/tool loop and its terminal outcome.
///
/// A Timeline has at most one active foreground Turn (ADR 0021). A distinct
/// Turn that arrives while another is active is rejected with
/// ``AscendantTurnError/timelineBusy(timelineID:clientTurnID:)`` before the
/// ledger admits it or the backend sees it. It is never queued.
///
/// Admission identity, the message digest, and terminal outcomes live in the
/// Turn ledger (``AscendantTurnUpdateStore``). The coordinator keeps only
/// scheduling: the active Turn per Timeline, in-flight tasks, and observers.
public actor AscendantTurnCoordinator {
    public typealias TurnOperation = @Sendable () async throws -> String

    private struct Key: Hashable, Sendable {
        let timelineID: UUID
        let clientTurnID: String
    }

    private struct InFlight: Sendable {
        let operationID: String
        let task: Task<String, Error>
        let cancel: @Sendable () async -> Void
    }

    /// The one active foreground Turn on a Timeline.
    private struct ActiveTurn: Sendable {
        let operationID: String
        let task: Task<String, Error>
    }

    private let ledger: AscendantTurnUpdateStore
    private let observers: [any TerminalTurnObserving]
    private let observationDrainTimeout: Duration
    private let observationScope: RuntimeEffectScope
    private var inFlight: [Key: InFlight] = [:]
    /// Timelines whose admission is being classified. A request waits here so it
    /// always observes the active Turn that an earlier admission registered, and
    /// two distinct Turns cannot both be admitted to one Timeline.
    private var admittingTimelines: Set<UUID> = []
    private var admissionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var activeTurns: [UUID: ActiveTurn] = [:]
    private var acceptingTurns = true
    /// Set when the bounded shutdown fence closes. Terminal outcomes committed
    /// after this point remain domain state, but cannot start observer work after
    /// the lifecycle has declared its observation boundary complete.
    private var observationClosed = false
    private var observationPending = 0
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []
    private var settlementWaiters: [CheckedContinuation<Void, Never>] = []

    /// The ledger's identity, outcome, and tombstone counts.
    internal var retainedStateCounts: (identities: Int, completed: Int, tombstones: Int, completedBytes: Int) {
        get async {
            let counts = await ledger.retainedIdentityCounts
            return (counts.identities, counts.outcomes, counts.retired, counts.outcomeBytes)
        }
    }

    internal var retainedIdentityCount: Int {
        get async { await ledger.retainedIdentityCounts.identities }
    }

    internal var retainedCapacity: (identities: Int, completed: Int) {
        get async { await ledger.admissionCapacities }
    }

    internal var retainedTimelineCount: Int { activeTurns.count }

    internal var inFlightCount: Int { inFlight.count }

    internal var observationPendingCount: Int { observationPending }

    internal var observationIsClosed: Bool { observationClosed }

    internal func observationSnapshot() async -> RuntimeEffectSnapshot {
        await observationScope.snapshot()
    }

    /// - Parameters:
    ///   - completedCapacity: Maximum number of terminal outcomes kept for replay
    ///     when the coordinator owns its ledger.
    ///   - identityCapacity: Maximum number of identified turns admitted during
    ///     this serve lifetime. Admitted identities are never evicted.
    ///   - observers: Ordered observers, each receiving one terminal record.
    ///   - observationDrainTimeout: Bound on waiting for committed observer
    ///     deliveries during shutdown. Conforming observers are non-blocking,
    ///     so the drain normally completes immediately; a stuck delivery is
    ///     cut off at this bound when the scope disposes.
    ///   - ledger: The Turn ledger that owns admission. A node passes the same
    ///     ledger it recovers from the durable log. When omitted, the coordinator
    ///     owns an in-memory ledger sized by the two capacities above.
    public init(
        completedCapacity: Int = 256,
        identityCapacity: Int = 1_024,
        observers: [any TerminalTurnObserving] = [],
        observationDrainTimeout: Duration = .seconds(1),
        ledger: AscendantTurnUpdateStore? = nil
    ) {
        self.ledger = ledger ?? AscendantTurnUpdateStore(
            maxEntries: max(1, identityCapacity),
            completedCapacity: completedCapacity,
            identityCapacity: identityCapacity
        )
        self.observers = observers
        self.observationDrainTimeout = observationDrainTimeout
        // This static label is validated by RuntimeEffectScope at construction.
        self.observationScope = try! RuntimeEffectScope(name: "turn-observation")
    }

    /// Cancels admitted work during node shutdown. New requests are rejected by
    /// the owning NodeRuntime before reaching this coordinator. Only real
    /// Turn-task completions terminalize a Turn: shutdown never fabricates an
    /// outcome, so a backend that ignores cancellation still commits and
    /// observes its real result. `true` awaits Turn and lane settlement
    /// without a bound; `false` gives the same settlement a window of
    /// `observationDrainTimeout`, so a Turn that honours cancellation is still
    /// observed and only genuinely noncooperative work is cut off by the
    /// fence. Both paths then drain committed observer deliveries up to
    /// `observationDrainTimeout` and dispose the scope.
    public func cancelAll(waitForCompletion: Bool = true) async {
        acceptingTurns = false
        let turns = Array(activeTurns.values.map(\.task) + inFlight.values.map(\.task))
        turns.forEach { $0.cancel() }

        if waitForCompletion {
            for turn in turns { _ = await turn.result }
        } else {
            await awaitSettlement(turns: turns, timeout: observationDrainTimeout)
        }
        // Close observer admission only after that window. A turn that settles
        // later still commits its replay state, but its observer delivery is
        // intentionally suppressed by the bounded shutdown policy.
        // Draining before disposal guarantees dispose never cancels a delivery
        // that was admitted before the fence without waiting for its declared
        // boundary.
        observationClosed = true
        await drainObservations(timeout: observationDrainTimeout)
        _ = await observationScope.dispose()
    }

    /// Cancels one admitted identified Turn without affecting another
    /// Timeline's lane or any other Turn on the backend.
    @discardableResult
    public func cancelTurn(timelineID: UUID, clientTurnID: String) async -> Bool {
        guard let canonicalID = try? GnosticWirePayload.canonicalClientTurnID(clientTurnID),
              let active = inFlight[Key(timelineID: timelineID, clientTurnID: canonicalID)] else {
            return false
        }
        await active.cancel()
        active.task.cancel()
        return true
    }

    /// Waits up to `timeout` for cancelled Turn tasks to settle, so
    /// cooperative work commits its terminal record while observer admission
    /// is still open. A task that outlives the window is abandoned rather than
    /// awaited: it holds no shutdown resource, and its later delivery is the
    /// case the observation fence exists for.
    private func awaitSettlement(
        turns: [Task<String, Error>],
        timeout: Duration
    ) async {
        guard !turns.isEmpty else { return }
        // Both tasks are actor-isolated, so neither can resolve the wait
        // before the continuation below is registered.
        let settlement = Task { [weak self] in
            for turn in turns { _ = await turn.result }
            await self?.resolveSettlement()
        }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolveSettlement()
        }
        // A waiter list, not a single slot: overlapping shutdowns must not
        // strand each other's continuation and hang cleanup.
        await withCheckedContinuation { continuation in
            settlementWaiters.append(continuation)
        }
        settlement.cancel()
        deadline.cancel()
    }

    private func resolveSettlement() {
        let waiters = settlementWaiters
        settlementWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Waits for committed observer deliveries up to `timeout`, so a
    /// contract-violating stuck observer cannot hold shutdown open.
    private func drainObservations(timeout: Duration) async {
        guard observationPending > 0 else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskCancellationHandler(operation: {
                    await self.awaitObservationDrain()
                }, onCancel: {
                    // Deliberately detached: the cancellation handler is
                    // synchronous and `abortObservationDrain` is
                    // actor-isolated. This hop only wakes an already-registered
                    // waiter; the drain join and the observation-scope disposal
                    // are awaited by `drainObservations`, and the group timeout
                    // bounds a waiter that never arrives. It is a signal, not
                    // cleanup work (#267).
                    Task { await self.abortObservationDrain() }
                })
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func awaitObservationDrain() async {
        while observationPending > 0, !Task.isCancelled {
            await withCheckedContinuation { continuation in
                observationWaiters.append(continuation)
            }
        }
    }

    private func abortObservationDrain() {
        let waiters = observationWaiters
        observationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Admits one turn. Requests without a client id use the compatibility path
    /// and are intentionally not deduplicated, while identified requests share
    /// one task per `(timelineID, clientTurnID)` key. A distinct request is
    /// rejected as busy while another Turn is active on the Timeline.
    public func execute(
        _ request: AscendantTurnRequest,
        ascendantID: UUID,
        cancel: @escaping @Sendable () async -> Void = {},
        operation: @escaping TurnOperation
    ) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        guard acceptingTurns else {
            throw Self.shuttingDown(for: request)
        }
        // The wire edge canonicalizes the client turn ID once; the ledger
        // receives the same canonical value.
        let canonicalRequest = AscendantTurnRequest(
            message: request.message,
            timelineID: request.timelineID,
            clientTurnID: try request.clientTurnID.map { try GnosticWirePayload.canonicalClientTurnID($0) },
            protocolMajor: request.protocolMajor
        )
        let admitted = try await admit(
            canonicalRequest,
            ascendantID: ascendantID,
            operationID: Self.makeOperationID(),
            cancel: cancel,
            operation: operation
        )
        switch admitted {
        case let .replayed(result):
            return result
        case let .attached(task):
            return try await replay(task, request: canonicalRequest)
        case let .started(task):
            let text = try await task.value
            return AscendantTurnResult(
                clientTurnID: canonicalRequest.clientTurnID ?? UUID().uuidString.lowercased(),
                text: text,
                replayed: false
            )
        }
    }

    private enum Admitted {
        /// The coordinator started this request's Turn.
        case started(Task<String, Error>)
        /// An identical retry that waits on the active Turn.
        case attached(Task<String, Error>)
        /// An identical retry answered from the ledger.
        case replayed(AscendantTurnResult)
    }

    /// Classifies one request while holding its Timeline's admission, so two
    /// distinct Turns can never both be admitted to one Timeline. A `.started`
    /// result has already registered the active Turn before admission ends.
    private func admit(
        _ request: AscendantTurnRequest,
        ascendantID: UUID,
        operationID: String,
        cancel: @escaping @Sendable () async -> Void,
        operation: @escaping TurnOperation
    ) async throws -> Admitted {
        let timelineID = request.timelineID
        await acquireAdmission(timelineID)
        defer { releaseAdmission(timelineID) }
        guard acceptingTurns else { throw Self.shuttingDown(for: request) }
        let timelineIsBusy = activeTurns[timelineID] != nil

        guard let clientTurnID = request.clientTurnID else {
            guard !timelineIsBusy else {
                throw AscendantTurnError.timelineBusy(timelineID: timelineID, clientTurnID: "")
            }
            return .started(start(
                request, key: nil, ascendantID: ascendantID, operationID: operationID,
                cancel: cancel, operation: operation
            ))
        }

        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID)
        let admission: TurnLedgerAdmission
        do {
            admission = try await ledger.admit(
                timelineID: timelineID,
                clientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID(rawValue: clientTurnID),
                message: request.message,
                admitNew: !timelineIsBusy
            )
        } catch AscendantTurnUpdateStore.Error.capacityExceeded {
            throw AscendantTurnError.capacityExceeded(timelineID: timelineID, clientTurnID: clientTurnID)
        }
        switch admission {
        case .new:
            return .started(start(
                request, key: key, ascendantID: ascendantID, operationID: operationID,
                cancel: cancel, operation: operation
            ))
        case .inFlight:
            guard let existing = inFlight[key] else {
                // Admitted but unregistered without a coordinator task: fail
                // closed rather than rerun the identity.
                throw AscendantTurnError.replayUnavailable(timelineID: timelineID, clientTurnID: clientTurnID)
            }
            return .attached(existing.task)
        case let .replay(.succeeded(text)):
            return .replayed(AscendantTurnResult(clientTurnID: clientTurnID, text: text, replayed: true))
        case let .replay(.failed(error)):
            throw error
        case .conflict:
            throw AscendantTurnError.conflict(timelineID: timelineID, clientTurnID: clientTurnID)
        case .unavailable:
            throw AscendantTurnError.replayUnavailable(timelineID: timelineID, clientTurnID: clientTurnID)
        case .busy:
            throw AscendantTurnError.timelineBusy(timelineID: timelineID, clientTurnID: clientTurnID)
        }
    }

    /// Starts the Turn's task and registers it as the Timeline's active Turn.
    /// Nothing suspends between creating the task and registering it, so the
    /// task's completion always finds its registration.
    private func start(
        _ request: AscendantTurnRequest,
        key: Key?,
        ascendantID: UUID,
        operationID: String,
        cancel: @escaping @Sendable () async -> Void,
        operation: @escaping TurnOperation
    ) -> Task<String, Error> {
        let timelineID = request.timelineID
        let clientTurnID = request.clientTurnID ?? ""
        let task = Task<String, Error> { [weak self] in
            let result: Result<String, any Error>
            do {
                try Task.checkCancellation()
                result = .success(try await Self.run(
                    operation, mappingFailures: key != nil, timelineID: timelineID, clientTurnID: clientTurnID
                ))
            } catch {
                result = .failure(error)
            }
            do {
                try await self?.recordCompletion(
                    key: key,
                    request: request,
                    ascendantID: ascendantID,
                    operationID: operationID,
                    result: result
                )
            } catch {
                await self?.releaseTimeline(timelineID, operationID: operationID)
                throw error
            }
            await self?.releaseTimeline(timelineID, operationID: operationID)
            return try result.get()
        }
        activeTurns[timelineID] = ActiveTurn(operationID: operationID, task: task)
        if let key {
            inFlight[key] = InFlight(operationID: operationID, task: task, cancel: cancel)
        }
        return task
    }

    /// Runs the backend operation and maps its failures onto the Turn errors a
    /// client sees. An unidentified compatibility Turn keeps the raw error.
    private static func run(
        _ operation: TurnOperation,
        mappingFailures: Bool,
        timelineID: UUID,
        clientTurnID: String
    ) async throws -> String {
        guard mappingFailures else { return try await operation() }
        do {
            return try await operation()
        } catch is CancellationError {
            throw AscendantTurnError.cancelled(timelineID: timelineID, clientTurnID: clientTurnID)
        } catch let error as AscendantBackendError {
            if case .cancelled = error {
                throw AscendantTurnError.cancelled(timelineID: timelineID, clientTurnID: clientTurnID)
            }
            if case let .lifecycleUnusable(failure) = error {
                throw AscendantTurnError.lifecycleUnusable(
                    timelineID: timelineID,
                    clientTurnID: clientTurnID,
                    detail: failure.message
                )
            }
            if case .insertionUnknown = error {
                throw AscendantTurnError.insertionUnknown(timelineID: timelineID, clientTurnID: clientTurnID)
            }
            if case let .terminal(failure) = error {
                throw AscendantTurnError.terminal(
                    timelineID: timelineID,
                    clientTurnID: clientTurnID,
                    code: failure.code,
                    detail: failure.message,
                    retryable: failure.retryable,
                    statusCode: 500
                )
            }
            throw AscendantTurnError.terminal(
                timelineID: timelineID,
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
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                detail: String(describing: error)
            )
        }
    }

    private static func shuttingDown(for request: AscendantTurnRequest) -> AscendantTurnError {
        .backendUnavailable(
            timelineID: request.timelineID,
            clientTurnID: request.clientTurnID ?? "",
            detail: "The Ascendant turn coordinator is shutting down."
        )
    }

    private func acquireAdmission(_ timelineID: UUID) async {
        while admittingTimelines.contains(timelineID) {
            await withCheckedContinuation { continuation in
                admissionWaiters[timelineID, default: []].append(continuation)
            }
        }
        admittingTimelines.insert(timelineID)
    }

    private func releaseAdmission(_ timelineID: UUID) {
        admittingTimelines.remove(timelineID)
        let waiters = admissionWaiters.removeValue(forKey: timelineID) ?? []
        waiters.forEach { $0.resume() }
    }

    /// Frees the Timeline once its Turn has committed its outcome.
    private func releaseTimeline(_ timelineID: UUID, operationID: String) {
        guard activeTurns[timelineID]?.operationID == operationID else { return }
        activeTurns.removeValue(forKey: timelineID)
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
    ) async throws {
        var committedOperationID = operationID
        if let key {
            guard let active = inFlight[key] else { return }
            committedOperationID = active.operationID
        }

        let outcome: TurnTerminalOutcome
        let terminalOutcome: TerminalTurnOutcome
        switch result {
        case let .success(text):
            outcome = .succeeded(text: text)
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
            // The outcome commits to the ledger before the in-flight slot
            // clears, so a duplicate admitted after the slot clears always
            // finds a terminal outcome instead of an unregistered identity.
            do {
                try await ledger.recordOutcome(
                    timelineID: key.timelineID,
                    clientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID(rawValue: key.clientTurnID),
                    outcome: outcome
                )
            } catch {
                inFlight.removeValue(forKey: key)
                throw error
            }
            inFlight.removeValue(forKey: key)
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
        // Bounded shutdown is an explicit observation fence. Delivering inline
        // here would let a late backend completion run observer work after the
        // host reported its cooperative lifecycle boundary complete.
        guard !observationClosed else {
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
            // The scope closed concurrently with shutdown. The bounded policy
            // fences this delivery rather than creating an unowned fallback.
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
        case let .timelineBusy(timelineID, clientTurnID):
            return .timelineBusy(timelineID: timelineID, clientTurnID: clientTurnID)
        case let .insertionUnknown(timelineID, clientTurnID):
            return .insertionUnknown(timelineID: timelineID, clientTurnID: clientTurnID)
        }
    }
}
