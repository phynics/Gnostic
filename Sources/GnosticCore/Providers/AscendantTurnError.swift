// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Terminal failures retained by the serve-lifetime turn coordinator.
public enum AscendantTurnError: Error, Sendable, Equatable, LocalizedError {
    case conflict(timelineID: UUID, clientTurnID: String)
    case failed(timelineID: UUID, clientTurnID: String, detail: String)
    case terminal(timelineID: UUID, clientTurnID: String, code: String, detail: String, retryable: Bool, statusCode: Int = 500)
    case cancelled(timelineID: UUID, clientTurnID: String)
    case lifecycleUnusable(timelineID: UUID, clientTurnID: String, detail: String)
    case backendUnavailable(timelineID: UUID, clientTurnID: String, detail: String)
    case replayUnavailable(timelineID: UUID, clientTurnID: String)

    public var errorDescription: String? {
        switch self {
        case let .conflict(timelineID, clientTurnID):
            "clientTurnID \(clientTurnID) was already used with different content on Timeline \(timelineID.uuidString.lowercased())"
        case let .failed(_, _, detail):
            detail
        case let .terminal(_, _, _, detail, _, _):
            detail
        case let .cancelled(_, clientTurnID):
            "ascendant.turn turn \(clientTurnID) was cancelled"
        case let .lifecycleUnusable(_, _, detail):
            detail
        case let .backendUnavailable(_, _, detail):
            detail
        case let .replayUnavailable(_, clientTurnID):
            "the replay result for ascendant.turn turn \(clientTurnID) is no longer retained; the turn will not be rerun"
        }
    }

    public var statusCode: Int {
        switch self {
        case .conflict: 409
        case .failed: 500
        case let .terminal(_, _, _, _, _, statusCode): Self.boundedStatusCode(statusCode)
        case .cancelled: 499
        case .lifecycleUnusable, .backendUnavailable: 503
        case .replayUnavailable: 410
        }
    }

    public var reasonCode: String {
        switch self {
        case .conflict: "turnConflict"
        case .failed: "turnFailed"
        case let .terminal(_, _, code, _, _, _): code
        case .cancelled: "turnCancelled"
        case .lifecycleUnusable: "backendLifecycleUnusable"
        case .backendUnavailable: "backendUnavailable"
        case .replayUnavailable: "replayUnavailable"
        }
    }

    public var retryable: Bool {
        if case let .terminal(_, _, _, _, retryable, _) = self { return retryable }
        return false
    }

    /// A stable message for public protocol failures. Detail associated values
    /// remain available to local diagnostics but never cross the wire.
    public var publicMessage: String {
        switch self {
        case let .conflict(_, clientTurnID):
            "clientTurnID \(clientTurnID) was already used with different content"
        case .failed, .terminal:
            "The ascendant turn failed."
        case .cancelled:
            "The ascendant turn was cancelled."
        case .lifecycleUnusable:
            "The ascendant backend lifecycle is unavailable."
        case .backendUnavailable:
            "The ascendant backend is unavailable."
        case .replayUnavailable:
            "The replay result for ascendant.turn is no longer retained."
        }
    }
    private static func boundedStatusCode(_ value: Int) -> Int {
        guard (100...599).contains(value) else { return 500 }
        return value
    }

}
