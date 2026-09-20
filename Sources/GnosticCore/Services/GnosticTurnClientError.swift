// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Failures produced by the public turn client.
public enum GnosticTurnClientError: Error, Sendable, Equatable, LocalizedError {
    /// No live provider advertised the addressed Timeline.
    case timelineUnavailable(UUID)

    /// More than one provider advertised the addressed Timeline.
    case timelineAmbiguous(UUID)

    /// The response came from a different provider than the addressed one.
    case providerMismatch

    /// A stable, machine-readable reason label.
    public var reasonCode: String {
        switch self {
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .providerMismatch: "providerMismatch"
        }
    }

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .timelineUnavailable(id):
            "Timeline \(id.uuidString.lowercased()) was not discovered."
        case let .timelineAmbiguous(id):
            "Timeline \(id.uuidString.lowercased()) is advertised by more than one provider."
        case .providerMismatch:
            "The response came from a different provider than the addressed one."
        }
    }
}
