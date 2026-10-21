// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// Errors arising during Timeline-owned Turn admission, lifecycle, or execution.
public enum TimelineTurnError: Error, LocalizedError, Equatable, Sendable {
    case timelineBusy
    case conflictingPayload(clientTurnID: String)
    case insertionUnknown
    case turnCancelled
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
        let task: Task<TimelineTurnResult, Error>
    }

    private struct CompletedTurn: Sendable {
        let admissionDigest: String
        let sequence: Int
        let terminalOutcome: TimelineTurnTerminalOutcome
        let messageID: String?
        let updates: [TimelineTurnUpdate]
    }

    private struct RecordedPermissionDecision: Sendable {
        let decision: String
        let approved: Bool
        let recordedAt: Date
    }

    private var activeTurnsByTimeline: [UUID: ActiveTurn] = [:]
    private var completedTurns: [TurnKey: CompletedTurn] = [:]
    private var recordedPermissions: [String: RecordedPermissionDecision] = [:]

    public init() {}

    /// Executes a Timeline-owned Turn within the single-active-turn contract.
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

        let key = TurnKey(timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID)

        // 1. Check for active Turn on this Timeline.
        if let active = activeTurnsByTimeline[envelope.timelineID] {
            if active.clientTurnID == envelope.clientTurnID {
                if active.admissionDigest == envelope.admissionDigest {
                    // Idempotent retry of active turn: await and return existing outcome without duplicate prompt.
                    return try await active.task.value
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

        // 3. Admitted: dispatch session/prompt within insertion lifecycle.
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
                await coordinator.finishTurn(key: key, outcome: .insertionUnknown, messageID: nil)
                throw error
            } catch is CancellationError {
                // A cancelled insertion was explicitly cancelled by the host.
                inFlightEnvelope.state = .cancelled
                inFlightEnvelope.terminalOutcome = .cancelled
                await coordinator.finishTurn(key: key, outcome: .cancelled, messageID: nil)
                throw TimelineTurnError.turnCancelled
            } catch {
                // Ambiguous or transport failure before message confirmation enters insertionUnknown.
                inFlightEnvelope.state = .insertionUnknown
                inFlightEnvelope.terminalOutcome = .insertionUnknown
                await coordinator.finishTurn(key: key, outcome: .insertionUnknown, messageID: nil)
                throw TimelineTurnError.insertionUnknown
            }

            // A cancellation may arrive while the insertion Call is in flight.
            if Task.isCancelled {
                inFlightEnvelope.state = .cancelled
                inFlightEnvelope.terminalOutcome = .cancelled
                await coordinator.finishTurn(key: key, outcome: .cancelled, messageID: messageID)
                throw TimelineTurnError.turnCancelled
            }

            // Prompt confirmed and inserted. Turn is active.
            inFlightEnvelope.state = .active

            // The session's idle update owns the terminal outcome. Fall back to
            // the envelope or endedUnspecified when the session omits it.
            let outcome = await coordinator.recordedOutcome(for: key)
                ?? inFlightEnvelope.terminalOutcome
                ?? .endedUnspecified
            let result = TimelineTurnResult(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                sequence: envelope.sequence,
                terminalOutcome: outcome,
                replayed: false,
                messageID: messageID,
                protocolMajor: GnosticProtocol.currentMajor
            )

            await coordinator.finishTurn(key: key, outcome: outcome, messageID: messageID)
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
            task: task
        )

        do {
            return try await task.value
        } catch {
            activeTurnsByTimeline.removeValue(forKey: envelope.timelineID)
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
    ) {
        guard let active = activeTurnsByTimeline.removeValue(forKey: key.timelineID),
              active.clientTurnID == key.clientTurnID else { return }
        completedTurns[key] = CompletedTurn(
            admissionDigest: active.admissionDigest,
            sequence: active.sequence,
            terminalOutcome: outcome,
            messageID: messageID ?? active.messageID,
            updates: active.updates
        )
    }

    /// Records a streamed update for replay and forwards it to the stream handler.
    public func recordUpdate(_ update: TimelineTurnUpdate) async {
        guard var active = activeTurnsByTimeline[update.timelineID],
              active.clientTurnID == update.clientTurnID else { return }
        active.updates.append(update)
        if update.terminal {
            active.terminalOutcome = update.terminalOutcome
        }
        let handler = active.updateHandler
        activeTurnsByTimeline[update.timelineID] = active
        await handler?(update)
    }

    /// Records an idle update's terminal outcome without completing the in-flight
    /// dispatch. ``execute(envelope:promptDispatch:streamUpdates:)`` reads it when
    /// the insertion Call returns.
    public func recordTerminalUpdate(
        timelineID: UUID,
        clientTurnID: String,
        stopReason: ACPStopReason?
    ) {
        guard var active = activeTurnsByTimeline[timelineID], active.clientTurnID == clientTurnID else { return }
        active.terminalOutcome = TimelineTurnTerminalOutcome.from(stopReason: stopReason)
        active.state = .completed
        activeTurnsByTimeline[timelineID] = active
    }

    /// Cancels an active turn on the Timeline if present.
    public func cancel(timelineID: UUID, clientTurnID: String) -> Bool {
        guard let active = activeTurnsByTimeline[timelineID], active.clientTurnID == clientTurnID else {
            return false
        }
        active.task.cancel()
        activeTurnsByTimeline.removeValue(forKey: timelineID)
        let key = TurnKey(timelineID: timelineID, clientTurnID: clientTurnID)
        completedTurns[key] = CompletedTurn(
            admissionDigest: active.admissionDigest,
            sequence: active.sequence,
            terminalOutcome: .cancelled,
            messageID: active.messageID,
            updates: active.updates
        )
        return true
    }

    private func recordedOutcome(for key: TurnKey) -> TimelineTurnTerminalOutcome? {
        guard let active = activeTurnsByTimeline[key.timelineID],
              active.clientTurnID == key.clientTurnID else { return nil }
        return active.terminalOutcome
    }

    /// Replays updates for a previously recorded turn.
    public func replay(timelineID: UUID, clientTurnID: String) -> TimelineTurnReplay? {
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
        do {
            let response = try await withThrowingTaskGroup(of: TimelinePermissionResponse.self) { group in
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

            recordedPermissions[request.correlationID] = RecordedPermissionDecision(
                decision: response.decision ?? (response.approved ? "approved" : "denied"),
                approved: response.approved,
                recordedAt: Date()
            )
            return response
        } catch {
            // Unanswered within timeout bound: record decision as unavailable.
            recordedPermissions[request.correlationID] = RecordedPermissionDecision(
                decision: "unavailable",
                approved: false,
                recordedAt: Date()
            )
            // Error code -32800 (requestCancelled).
            throw ACPError.requestCancelled("Permission request timed out; decision recorded as unavailable")
        }
    }
}
