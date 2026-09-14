// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The bounded failure details that a terminal Turn may expose to an observer.
/// Backend-specific detail and result text remain outside this contract.
public struct TerminalTurnFailure: Sendable, Equatable {
    public let reasonCode: String
    public let statusCode: Int
    public let retryable: Bool

    public init(reasonCode: String, statusCode: Int, retryable: Bool = false) {
        self.reasonCode = GnosticWirePayload.boundedIdentifier(reasonCode)
        self.statusCode = GnosticProtocol.boundedStatusCode(statusCode)
        self.retryable = retryable
    }
}

/// The backend-neutral terminal classification delivered to observers.
public enum TerminalTurnOutcome: Sendable, Equatable {
    case succeeded
    case failed(TerminalTurnFailure)
    case cancelled
}

/// The immutable Gnostic record for one originally admitted terminal Turn.
public struct TerminalTurnRecord: Sendable, Equatable {
    public let operationID: String
    public let ascendantID: UUID
    public let timelineID: UUID
    public let clientTurnID: String?
    public let outcome: TerminalTurnOutcome

    public init(
        operationID: String,
        ascendantID: UUID,
        timelineID: UUID,
        clientTurnID: String?,
        outcome: TerminalTurnOutcome
    ) {
        self.operationID = operationID
        self.ascendantID = ascendantID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.outcome = outcome
    }
}

/// Receives each original terminal Turn once. Implementations must be low-cost
/// and non-blocking: append or enqueue the immutable record locally rather
/// than performing model calls, network I/O, or semantic integration inline.
/// Any suspension must use cancellable primitives: shutdown drains pending
/// deliveries up to a bound, then disposes the observation scope, which
/// cancels a still-stuck delivery. A non-cancellable infinite wait would hang
/// disposal itself. Implementations must not assume that observation
/// succeeds; the coordinator contains every thrown failure.
public protocol TerminalTurnObserving: Sendable {
    func observe(_ record: TerminalTurnRecord) async throws
}
