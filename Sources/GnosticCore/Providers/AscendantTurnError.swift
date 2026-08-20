// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Terminal failures retained by the serve-lifetime turn coordinator.
public enum AscendantTurnError: Error, Sendable, Equatable, LocalizedError {
    case conflict(timelineID: UUID, clientTurnID: String)
    case failed(timelineID: UUID, clientTurnID: String, detail: String)
    case terminal(timelineID: UUID, clientTurnID: String, code: String, detail: String, retryable: Bool)
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
        case let .terminal(_, _, _, detail, _):
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
        case .failed, .terminal: 500
        case .cancelled: 499
        case .lifecycleUnusable, .backendUnavailable: 503
        case .replayUnavailable: 410
        }
    }

    public var reasonCode: String {
        switch self {
        case .conflict: "turnConflict"
        case .failed: "turnFailed"
        case let .terminal(_, _, code, _, _): code
        case .cancelled: "turnCancelled"
        case .lifecycleUnusable: "backendLifecycleUnusable"
        case .backendUnavailable: "backendUnavailable"
        case .replayUnavailable: "replayUnavailable"
        }
    }

    public var retryable: Bool {
        if case let .terminal(_, _, _, _, retryable) = self { return retryable }
        return false
    }

    public var publicMessage: String { localizedDescription }
}
