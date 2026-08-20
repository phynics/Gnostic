// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Terminal failures retained by the serve-lifetime turn coordinator.
public enum AscendantTurnError: Error, Sendable, Equatable, LocalizedError {
    case conflict(timelineID: UUID, clientTurnID: String)
    case failed(timelineID: UUID, clientTurnID: String, detail: String)
    case cancelled(timelineID: UUID, clientTurnID: String)
    case lifecycleUnusable(timelineID: UUID, clientTurnID: String, detail: String)
    case replayUnavailable(timelineID: UUID, clientTurnID: String)

    public var errorDescription: String? {
        switch self {
        case let .conflict(timelineID, clientTurnID):
            "clientTurnID \(clientTurnID) was already used with different content on Timeline \(timelineID.uuidString.lowercased())"
        case let .failed(_, _, detail):
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
        case .failed: 500
        case .lifecycleUnusable: 503
        case .cancelled: 499
        case .replayUnavailable: 410
        }
    }
}
