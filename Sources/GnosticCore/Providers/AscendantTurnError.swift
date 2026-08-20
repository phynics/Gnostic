// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Terminal failures retained by the serve-lifetime turn coordinator.
public enum AscendantTurnError: Error, Sendable, Equatable, LocalizedError {
    case conflict(timelineID: UUID, clientTurnID: String)
    case failed(timelineID: UUID, clientTurnID: String, detail: String)
    case terminal(timelineID: UUID, clientTurnID: String, code: String, detail: String, retryable: Bool)
    case cancelled(timelineID: UUID, clientTurnID: String)
    case lifecycleUnusable(timelineID: UUID, clientTurnID: String, detail: String)
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
            "agent.chat turn \(clientTurnID) was cancelled"
        case let .lifecycleUnusable(_, clientTurnID, detail):
            "agent.chat turn \(clientTurnID) cannot run because its backend lifecycle is unusable: \(detail)"
        case let .replayUnavailable(_, clientTurnID):
            "the replay result for agent.chat turn \(clientTurnID) is no longer retained; the turn will not be rerun"
        }
    }

    public var statusCode: Int {
        switch self {
        case .conflict: 409
        case .failed, .terminal: 500
        case .lifecycleUnusable: 503
        case .cancelled: 499
        case .replayUnavailable: 410
        }
    }

    /// Stable terminal code retained from an Ascendant backend failure.
    public var reasonCode: String {
        switch self {
        case .conflict: return "turnConflict"
        case .failed: return "turnFailed"
        case let .terminal(_, _, code, _, _): return code
        case .cancelled: return "cancelled"
        case .lifecycleUnusable: return "backendLifecycleUnusable"
        case .replayUnavailable: return "replayUnavailable"
        }
    }

    /// Whether a backend terminal failure may be retried by a caller.
    public var retryable: Bool {
        if case let .terminal(_, _, _, _, retryable) = self { return retryable }
        return false
    }

    /// Error text for transports that expose only a status and message while
    /// retaining the backend's structured terminal metadata.
    public var publicMessage: String {
        "\(reasonCode): \(localizedDescription) (retryable=\(retryable))"
    }
}
