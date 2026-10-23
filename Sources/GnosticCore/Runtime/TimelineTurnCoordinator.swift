// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// Errors arising during Timeline-owned Turn admission, lifecycle, or execution.
public enum TimelineTurnError: Error, LocalizedError, Equatable, Sendable {
    case timelineBusy
    case conflictingPayload(clientTurnID: String)
    case insertionUnknown
    case turnCancelled
    case journalUnavailable(String)
    case failed(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .timelineBusy:
            return "Timeline is busy"
        case let .conflictingPayload(id):
            return "Conflicting prompt payload under identical clientTurnID '\(id)'"
        case .insertionUnknown:
            return "Prompt dispatch response lost or ambiguous; turn entered insertionUnknown"
        case .turnCancelled:
            return "Timeline turn was cancelled"
        case let .journalUnavailable(reason):
            return "Timeline journal is unavailable: \(reason)"
        case let .failed(code, message):
            return "\(code): \(message)"
        }
    }

    public var jsonRPCErrorCode: Int {
        switch self {
        case .timelineBusy:
            return -32001
        case .conflictingPayload:
            return -32602
        case .insertionUnknown:
            return -32000
        case .turnCancelled:
            return -32800
        case .journalUnavailable:
            return -32603
        case .failed:
            return -32603
        }
    }

    public var structuredData: [String: AnySendable] {
        switch self {
        case .timelineBusy:
            return [
                "code": AnySendable("timelineBusy"),
                "retryable": AnySendable(true)
            ]
        default:
            return [:]
        }
    }
}

/// Type-erased sendable value for structured error data.
public struct AnySendable: Sendable, Codable, Equatable {
    private enum Storage: Sendable, Equatable {
        case string(String)
        case bool(Bool)
    }

    private let storage: Storage

    public init(_ string: String) {
        storage = .string(string)
    }

    public init(_ bool: Bool) {
        storage = .bool(bool)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            storage = .bool(bool)
        } else {
            storage = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case let .string(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        }
    }
}

/// Coordinates Timeline-owned Turn admission, busy rejection, idempotent retry,
/// prompt insertion lifecycle, and host-mediated permission timeout.
public actor TimelineTurnCoordinator {
    public struct TurnKey: Hashable, Sendable {
        public let timelineID: UUID
        public let clientTurnID: String

        public init(timelineID: UUID, clientTurnID: String) {
            self.timelineID = timelineID
            self.clientTurnID = clientTurnID
        }
    }

    private struct ActiveTurn {
        let clientTurnID: String
        let admissionDigest: String
        let sequence: Int
        var state: TimelineTurnLifecycleState
        var messageID: String?
        var terminalOutcome: TimelineTurnTerminalOutcome?
        var updates: [TimelineTurnUpdate]
        var updateHandler: (@Sendable (TimelineTurnUpdate) async -> Void)?
        var terminalContinuation: AsyncStream<TimelineTurnTerminalOutcome>.Continuation?
        let task: Task<TimelineTurnResult, Error>
    }

    private struct CompletedTurn: Sendable {
        let admissionDigest: String
        let sequence: Int
        let terminalOutcome: TimelineTurnTerminalOutcome
        let messageID: String?
        var updates: [TimelineTurnUpdate]
    }

    private struct RecordedPermissionDecision: Sendable {
        let decision: String
        let approved: Bool
        let recordedAt: Date
    }

    private var activeTurnsByTimeline: [UUID: ActiveTurn] = [:]
    private var completedTurns: [TurnKey: CompletedTurn] = [:]
    private var recordedPermissions: [String: RecordedPermissionDecision] = [:]
    private var recoveryTasks: [UUID: Task<TimelineJournal, Error>] = [:]
    private var recoveredTimelines: Set<UUID> = []
    private var terminalizingTurns: Set<TurnKey> = []
    private var admissionLocks: Set<UUID> = []
    private var admissionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let journals: TimelineJournalStore

    public init(journals: TimelineJournalStore) {
        self.journals = journals
    }

    /// Executes a Timeline-owned Turn within the single-active-turn contract.
    ///
    /// The prompt response is only the insertion handshake. The Turn stays
    /// active until the session emits its terminal update, the Turn is
    /// cancelled, or the insertion fails, so a second Turn cannot be admitted
    /// on the same Timeline while the first one is still running.
    ///
    /// - Parameters:
    ///   - envelope: The turn envelope containing prompt blocks and metadata.
    ///   - promptDispatch: The operation that dispatches `session/prompt` and returns `messageId`.
    ///   - streamUpdates: Optional handler to deliver streamed `TimelineTurnUpdate` items.
    /// - Returns: The final `TimelineTurnResult`.
    public func execute(
        envelope: TimelineTurnEnvelope,
        promptDispatch: @Sendable @escaping (TimelineTurnEnvelope) async throws -> String,
        streamUpdates: (@Sendable (TimelineTurnUpdate) async -> Void)? = nil
    ) async throws -> TimelineTurnResult {
        try GnosticProtocol.validate(envelope.protocolMajor)
        await acquireAdmissionLock(for: envelope.timelineID)
        var holdsAdmissionLock = true
        defer {
            if holdsAdmissionLock { releaseAdmissionLock(for: envelope.timelineID) }
        }
        let journal = try await recoverTimelineIfNeeded(envelope.timelineID)

        let key = TurnKey(timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID)

        // 1. Check for active Turn on this Timeline.
        if let active = activeTurnsByTimeline[envelope.timelineID] {
            if active.clientTurnID == envelope.clientTurnID {
                if active.admissionDigest == envelope.admissionDigest {
                    // Idempotent retry of active turn: await and return existing outcome without duplicate prompt.
                    let task = active.task
                    releaseAdmissionLock(for: envelope.timelineID)
                    holdsAdmissionLock = false
                    return try await task.value
                } else {
                    // Conflicting prompt payload under identical clientTurnID.
                    throw TimelineTurnError.conflictingPayload(clientTurnID: envelope.clientTurnID)
                }
            } else {
                // One active foreground Turn per Timeline: reject as busy before insertion.
                // No prompt response is fabricated.
                throw TimelineTurnError.timelineBusy
            }
        }

        // 2. Check for previously completed Turn with the same identity.
        if let completed = completedTurns[key] {
            if completed.admissionDigest == envelope.admissionDigest {
                // Idempotent retry of completed turn: replay existing terminal outcome.
                return TimelineTurnResult(
                    timelineID: envelope.timelineID,
                    clientTurnID: envelope.clientTurnID,
                    sequence: completed.sequence,
                    terminalOutcome: completed.terminalOutcome,
                    replayed: true,
                    messageID: completed.messageID,
                    protocolMajor: GnosticProtocol.currentMajor
                )
            } else {
                throw TimelineTurnError.conflictingPayload(clientTurnID: envelope.clientTurnID)
            }
        }

        // Commit admission before `session/prompt`. If this append fails, the
        // Runtime must not observe the prompt.
        try await append(.turnAdmitted(
            clientTurnID: envelope.clientTurnID,
            admissionDigest: envelope.admissionDigest,
            turnSequence: envelope.sequence,
            acpVersionTag: envelope.acpVersionTag,
            prompt: envelope.prompt
        ), to: journal)

        // Admitted: dispatch session/prompt within insertion lifecycle.
        // The terminal stream carries the outcome that ends the Turn.
        let (terminalStream, terminalContinuation) = AsyncStream<TimelineTurnTerminalOutcome>.makeStream()
        let coordinator = self
        let task = Task<TimelineTurnResult, Error> {
            var inFlightEnvelope = envelope
            inFlightEnvelope.state = .pendingInsertion

            let messageID: String
            do {
                messageID = try await promptDispatch(inFlightEnvelope)
                inFlightEnvelope.messageID = messageID
                inFlightEnvelope.state = .inserted
            } catch let error as TimelineTurnError where error == .insertionUnknown {
                inFlightEnvelope.state = .insertionUnknown
                inFlightEnvelope.terminalOutcome = .insertionUnknown
                terminalContinuation.finish()
                try await coordinator.finishTurn(key: key, outcome: .insertionUnknown, messageID: nil)
                throw error
            } catch is CancellationError {
                // A cancelled insertion was explicitly cancelled by the host.
                inFlightEnvelope.state = .cancelled
                inFlightEnvelope.terminalOutcome = .cancelled
                terminalContinuation.finish()
                try await coordinator.finishTurn(key: key, outcome: .cancelled, messageID: nil)
                throw TimelineTurnError.turnCancelled
            } catch {
                // Ambiguous or transport failure before message confirmation enters insertionUnknown.
                inFlightEnvelope.state = .insertionUnknown
                inFlightEnvelope.terminalOutcome = .insertionUnknown
                terminalContinuation.finish()
                try await coordinator.finishTurn(key: key, outcome: .insertionUnknown, messageID: nil)
                throw TimelineTurnError.insertionUnknown
            }

            // A cancellation may arrive while the insertion Call is in flight.
            if Task.isCancelled {
                inFlightEnvelope.state = .cancelled
                inFlightEnvelope.terminalOutcome = .cancelled
                terminalContinuation.finish()
                try await coordinator.finishTurn(key: key, outcome: .cancelled, messageID: messageID)
                throw TimelineTurnError.turnCancelled
            }

            // Prompt confirmed and inserted. The Turn is active until the
            // session emits its terminal update, the Turn is cancelled, or the
            // stream ends.
            inFlightEnvelope.state = .active

            var terminalOutcome: TimelineTurnTerminalOutcome?
            for await outcome in terminalStream {
                terminalOutcome = outcome
                break
            }
            terminalContinuation.finish()

            let outcome = terminalOutcome
                ?? inFlightEnvelope.terminalOutcome
                ?? .endedUnspecified
            if outcome == .cancelled {
                // The Turn was cancelled while it was active.
                inFlightEnvelope.state = .cancelled
                try await coordinator.finishTurn(key: key, outcome: .cancelled, messageID: messageID)
                throw TimelineTurnError.turnCancelled
            }
            let result = TimelineTurnResult(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                sequence: envelope.sequence,
                terminalOutcome: outcome,
                replayed: false,
                messageID: messageID,
                protocolMajor: GnosticProtocol.currentMajor
            )

            try await coordinator.finishTurn(key: key, outcome: outcome, messageID: messageID)
            return result
        }

        activeTurnsByTimeline[envelope.timelineID] = ActiveTurn(
            clientTurnID: envelope.clientTurnID,
            admissionDigest: envelope.admissionDigest,
            sequence: envelope.sequence,
            state: .pendingInsertion,
            messageID: nil,
            terminalOutcome: nil,
            updates: [],
            updateHandler: streamUpdates,
            terminalContinuation: terminalContinuation,
            task: task
        )
        releaseAdmissionLock(for: envelope.timelineID)
        holdsAdmissionLock = false

        do {
            return try await task.value
        } catch {
            if activeTurnsByTimeline[envelope.timelineID]?.clientTurnID == envelope.clientTurnID {
                activeTurnsByTimeline.removeValue(forKey: envelope.timelineID)
            }
            terminalContinuation.finish()
            throw error
        }
    }

    /// Records completion of a turn in the ledger and clears active state.
    ///
    /// A completion that races with ``cancel(timelineID:clientTurnID:)`` finds
    /// no active turn and must not overwrite the recorded cancellation.
    fileprivate func finishTurn(
        key: TurnKey,
        outcome: TimelineTurnTerminalOutcome,
        messageID: String?
    ) async throws {
        guard let active = activeTurnsByTimeline[key.timelineID],
              active.clientTurnID == key.clientTurnID else { return }
        guard terminalizingTurns.insert(key).inserted else {
            throw TimelineTurnError.turnCancelled
        }
        defer { terminalizingTurns.remove(key) }
        let journal = try await journal(for: key.timelineID)
        try await append(.turnCompleted(
            clientTurnID: key.clientTurnID,
            outcome: outcome,
            messageID: messageID ?? active.messageID
        ), to: journal)
        guard let completedActive = activeTurnsByTimeline[key.timelineID],
              completedActive.clientTurnID == key.clientTurnID else { return }
        activeTurnsByTimeline.removeValue(forKey: key.timelineID)
        completedTurns[key] = CompletedTurn(
            admissionDigest: completedActive.admissionDigest,
            sequence: completedActive.sequence,
            terminalOutcome: outcome,
            messageID: messageID ?? completedActive.messageID,
            updates: completedActive.updates
        )
    }

    /// Records a streamed update for replay and forwards it to the stream handler.
    ///
    /// A terminal update ends the Turn: it owns the terminal outcome and
    /// releases the awaiting ``execute(envelope:promptDispatch:streamUpdates:)``.
    public func recordUpdate(_ update: TimelineTurnUpdate, sessionID: String = "") async throws {
        let journal = try await journal(for: update.timelineID)
        try await append(.acpUpdate(sessionID: sessionID, update: update), to: journal)
        guard var active = activeTurnsByTimeline[update.timelineID],
              active.clientTurnID == update.clientTurnID else {
            let key = TurnKey(timelineID: update.timelineID, clientTurnID: update.clientTurnID)
            if var completed = completedTurns[key] {
                completed.updates.append(update)
                completedTurns[key] = completed
            }
            return
        }
        active.updates.append(update)
        if update.terminal {
            active.terminalOutcome = update.terminalOutcome
            active.state = .completed
            active.terminalContinuation?.yield(update.terminalOutcome ?? .endedUnspecified)
            active.terminalContinuation = nil
        }
        let handler = active.updateHandler
        activeTurnsByTimeline[update.timelineID] = active
        await handler?(update)
    }

    /// Records an idle update's terminal outcome and ends the active Turn.
    ///
    /// The Turn stays active until this signal arrives, so a second Turn cannot
    /// be admitted on the same Timeline while the first one is still running.
    public func recordTerminalUpdate(
        timelineID: UUID,
        clientTurnID: String,
        stopReason: ACPStopReason?
    ) async throws {
        guard var active = activeTurnsByTimeline[timelineID], active.clientTurnID == clientTurnID else { return }
        let outcome = TimelineTurnTerminalOutcome.from(stopReason: stopReason)
        active.terminalOutcome = outcome
        active.state = .completed
        active.terminalContinuation?.yield(outcome)
        active.terminalContinuation = nil
        activeTurnsByTimeline[timelineID] = active
    }

    /// Cancels an active turn on the Timeline if present.
    public func cancel(timelineID: UUID, clientTurnID: String) async throws -> Bool {
        await acquireAdmissionLock(for: timelineID)
        defer { releaseAdmissionLock(for: timelineID) }
        guard let active = activeTurnsByTimeline[timelineID], active.clientTurnID == clientTurnID else {
            return false
        }
        let key = TurnKey(timelineID: timelineID, clientTurnID: clientTurnID)
        guard terminalizingTurns.insert(key).inserted else { return false }
        defer { terminalizingTurns.remove(key) }
        let journal = try await journal(for: timelineID)
        try await append(.turnCompleted(
            clientTurnID: clientTurnID,
            outcome: .cancelled,
            messageID: active.messageID
        ), to: journal)
        let journalUpdates = (try? await journal.replay())?.compactMap { record -> TimelineTurnUpdate? in
            guard case let .acpUpdate(_, update) = record.payload,
                  update.timelineID == timelineID,
                  update.clientTurnID == clientTurnID else { return nil }
            return update
        }
        let current = activeTurnsByTimeline[timelineID].flatMap {
            $0.clientTurnID == clientTurnID ? $0 : nil
        }
        let latest = current ?? active
        latest.task.cancel()
        current?.terminalContinuation?.yield(.cancelled)
        current?.terminalContinuation?.finish()
        activeTurnsByTimeline.removeValue(forKey: timelineID)
        completedTurns[key] = CompletedTurn(
            admissionDigest: latest.admissionDigest,
            sequence: latest.sequence,
            terminalOutcome: .cancelled,
            messageID: latest.messageID,
            updates: journalUpdates ?? latest.updates
        )
        return true
    }

    /// Replays updates for a previously recorded turn.
    public func replay(timelineID: UUID, clientTurnID: String) async throws -> TimelineTurnReplay? {
        _ = try await recoverTimelineIfNeeded(timelineID)
        let key = TurnKey(timelineID: timelineID, clientTurnID: clientTurnID)
        guard let completed = completedTurns[key] else { return nil }
        return TimelineTurnReplay(
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            updates: completed.updates,
            terminalOutcome: completed.terminalOutcome,
            protocolMajor: GnosticProtocol.currentMajor
        )
    }

    /// Mediates a host permission request crossing Node boundaries with a timeout bound.
    ///
    /// If unresponded within timeout, returns JSON-RPC error code -32800 and records
    /// the decision as "unavailable". Replay preserves the recorded decision and never prompts again.
    public func mediatePermission(
        request: TimelinePermissionRequest,
        timeout: Duration = .seconds(5),
        clientPrompt: @Sendable @escaping (TimelinePermissionRequest) async throws -> TimelinePermissionResponse
    ) async throws -> TimelinePermissionResponse {
        try GnosticProtocol.validate(request.protocolMajor)
        let journal = try await recoverTimelineIfNeeded(request.timelineID)

        // If previously recorded, replay preserves recorded decision and never prompts again.
        if let existing = recordedPermissions[request.correlationID] {
            return TimelinePermissionResponse(
                correlationID: request.correlationID,
                timelineID: request.timelineID,
                clientTurnID: request.clientTurnID,
                approved: existing.approved,
                decision: existing.decision,
                protocolMajor: GnosticProtocol.currentMajor
            )
        }

        // Wait for client prompt within timeout bound.
        let response: TimelinePermissionResponse
        do {
            response = try await withThrowingTaskGroup(of: TimelinePermissionResponse.self) { group in
                group.addTask {
                    try await clientPrompt(request)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ACPError.requestCancelled("Permission request timed out waiting for client response")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            // Unanswered within timeout bound: record decision as unavailable.
            try await append(.permissionDecision(
                correlationID: request.correlationID,
                clientTurnID: request.clientTurnID,
                decision: "unavailable",
                approved: false
            ), to: journal)
            recordedPermissions[request.correlationID] = RecordedPermissionDecision(
                decision: "unavailable",
                approved: false,
                recordedAt: Date()
            )
            // Error code -32800 (requestCancelled).
            throw ACPError.requestCancelled("Permission request timed out; decision recorded as unavailable")
        }

        let decision = response.decision ?? (response.approved ? "approved" : "denied")
        try await append(.permissionDecision(
            correlationID: request.correlationID,
            clientTurnID: request.clientTurnID,
            decision: decision,
            approved: response.approved
        ), to: journal)
        recordedPermissions[request.correlationID] = RecordedPermissionDecision(
            decision: decision,
            approved: response.approved,
            recordedAt: Date()
        )
        return response
    }

    private func recoverTimelineIfNeeded(_ timelineID: UUID) async throws -> TimelineJournal {
        if let pending = recoveryTasks[timelineID] { return try await pending.value }
        let task = Task { try await self.recoverTimeline(timelineID) }
        recoveryTasks[timelineID] = task
        defer { recoveryTasks.removeValue(forKey: timelineID) }
        return try await task.value
    }

    private func recoverTimeline(_ timelineID: UUID) async throws -> TimelineJournal {
        let journal = try await journal(for: timelineID)
        guard !recoveredTimelines.contains(timelineID) else { return journal }

        let records: [TimelineJournalRecord]
        do {
            records = try await journal.replay()
        } catch {
            recoveredTimelines.remove(timelineID)
            throw TimelineTurnError.journalUnavailable(error.localizedDescription)
        }

        var admissions: [String: (digest: String, sequence: Int)] = [:]
        var updates: [String: [TimelineTurnUpdate]] = [:]
        // An idle notification does not confirm prompt insertion. Only an
        // explicit committed completion resolves a recovered admission.
        var outcomes: [String: (outcome: TimelineTurnTerminalOutcome, messageID: String?)] = [:]
        for record in records {
            switch record.payload {
            case let .turnAdmitted(clientTurnID, admissionDigest, turnSequence, _, _):
                if let prior = admissions[clientTurnID], prior.digest != admissionDigest {
                    recoveredTimelines.remove(timelineID)
                    throw TimelineTurnError.journalUnavailable(
                        "conflicting durable admission for clientTurnID '\(clientTurnID)'"
                    )
                }
                admissions[clientTurnID] = (admissionDigest, turnSequence)
            case let .acpUpdate(_, update) where update.timelineID == timelineID:
                updates[update.clientTurnID, default: []].append(update)
            case let .turnCompleted(clientTurnID, outcome, messageID):
                outcomes[clientTurnID] = (outcome, messageID)
            case let .permissionDecision(correlationID, _, decision, approved):
                recordedPermissions[correlationID] = RecordedPermissionDecision(
                    decision: decision,
                    approved: approved,
                    recordedAt: record.timestamp
                )
            default:
                break
            }
        }

        for (clientTurnID, admission) in admissions {
            let key = TurnKey(timelineID: timelineID, clientTurnID: clientTurnID)
            let terminal = outcomes[clientTurnID]
            completedTurns[key] = CompletedTurn(
                admissionDigest: admission.digest,
                sequence: admission.sequence,
                terminalOutcome: terminal?.outcome ?? .insertionUnknown,
                messageID: terminal?.messageID,
                updates: updates[clientTurnID] ?? []
            )
        }
        recoveredTimelines.insert(timelineID)
        return journal
    }

    private func journal(for timelineID: UUID) async throws -> TimelineJournal {
        do {
            return try await journals.journal(for: timelineID)
        } catch {
            throw TimelineTurnError.journalUnavailable(error.localizedDescription)
        }
    }

    private func append(_ payload: TimelineJournalPayload, to journal: TimelineJournal) async throws {
        do {
            try await journal.append(payload)
        } catch {
            throw TimelineTurnError.journalUnavailable(error.localizedDescription)
        }
    }

    private func acquireAdmissionLock(for timelineID: UUID) async {
        guard admissionLocks.contains(timelineID) else {
            admissionLocks.insert(timelineID)
            return
        }
        await withCheckedContinuation { continuation in
            admissionWaiters[timelineID, default: []].append(continuation)
        }
    }

    private func releaseAdmissionLock(for timelineID: UUID) {
        if var waiters = admissionWaiters[timelineID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                admissionWaiters.removeValue(forKey: timelineID)
            } else {
                admissionWaiters[timelineID] = waiters
            }
            next.resume()
        } else {
            admissionLocks.remove(timelineID)
        }
    }
}
