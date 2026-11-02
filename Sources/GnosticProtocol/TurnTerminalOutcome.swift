// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation
import GnosticACPWire

/// Terminal state classification of a completed Timeline Turn.
public enum TurnTerminalOutcome: String, Codable, Sendable, Equatable {
    case completed
    case endedUnspecified
    case cancelled
    case failed
    case insertionUnknown
    case unavailable

    package static func from(stopReason: ACPStopReason?) -> TurnTerminalOutcome {
        guard let stopReason else { return .endedUnspecified }
        switch stopReason {
        case .endTurn, .maxTokens, .maxTurnRequests:
            return .completed
        case .cancelled:
            return .cancelled
        case .error, .refusal:
            return .failed
        case .other:
            return .endedUnspecified
        }
    }
}
