// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Failures produced by the public turn client.
public enum GnosticTurnClientError: Error, Sendable, Equatable, LocalizedError {
    /// No live provider advertised the addressed Timeline.
    case timelineUnavailable(UUID)

    /// More than one provider advertised the addressed Timeline.
    case timelineAmbiguous(UUID)

    /// The addressed provider does not own the Timeline, or the response came
    /// from a different provider than the addressed one.
    case providerMismatch

    /// The resolved Ascendant does not advertise the required capability.
    case missingCapability(String)

    /// The serve rejected the operation with a structured protocol failure.
    ///
    /// `reasonCode` is the serve's stable code, `statusCode` its HTTP-like
    /// status, and `retryable` whether the serve marked the failure retryable.
    case callFailed(reasonCode: String, statusCode: Int, retryable: Bool)

    /// A stable, machine-readable reason label.
    public var reasonCode: String {
        switch self {
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .providerMismatch: "providerMismatch"
        case .missingCapability: "missingCapability"
        case let .callFailed(reasonCode, _, _): reasonCode
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
            "The provider does not own the requested Timeline, or the response came from another provider."
        case let .missingCapability(capability):
            "The selected Ascendant does not advertise capability \(capability)."
        case let .callFailed(reasonCode, statusCode, _):
            "The serve rejected the operation: \(reasonCode) (status \(statusCode))."
        }
    }
}
