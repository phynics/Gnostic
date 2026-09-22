// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Failures produced by the public Timeline client.
public enum GnosticTimelineClientError: Error, Sendable, Equatable, LocalizedError {
    /// No live provider advertised the addressed Ascendant.
    case ascendantUnavailable(UUID)

    /// More than one provider advertised the addressed Ascendant.
    case ascendantAmbiguous(UUID)

    /// No live provider advertised the addressed Timeline.
    case timelineUnavailable(UUID)

    /// More than one provider advertised the addressed Timeline.
    case timelineAmbiguous(UUID)

    /// The resolved Ascendant does not advertise Timeline management.
    case missingCapability(String)

    /// The response came from a different provider than the addressed one.
    case providerMismatch

    /// The serve rejected the operation with a structured protocol failure.
    ///
    /// `reasonCode` is the serve's stable code, `statusCode` its HTTP-like
    /// status, and `retryable` whether the serve marked the failure retryable.
    case callFailed(reasonCode: String, statusCode: Int, retryable: Bool)

    /// A stable, machine-readable reason label.
    public var reasonCode: String {
        switch self {
        case .ascendantUnavailable: "ascendantUnavailable"
        case .ascendantAmbiguous: "ascendantAmbiguous"
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .missingCapability: "missingCapability"
        case .providerMismatch: "providerMismatch"
        case let .callFailed(reasonCode, _, _): reasonCode
        }
    }

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .ascendantUnavailable(id):
            "Ascendant \(id.uuidString.lowercased()) was not discovered."
        case let .ascendantAmbiguous(id):
            "Ascendant \(id.uuidString.lowercased()) is advertised by more than one provider."
        case let .timelineUnavailable(id):
            "Timeline \(id.uuidString.lowercased()) was not discovered."
        case let .timelineAmbiguous(id):
            "Timeline \(id.uuidString.lowercased()) is advertised by more than one provider."
        case let .missingCapability(capability):
            "The selected Ascendant does not advertise capability \(capability)."
        case .providerMismatch:
            "The response came from a provider other than the one selected from the catalog."
        case let .callFailed(reasonCode, statusCode, _):
            "The serve rejected the operation: \(reasonCode) (status \(statusCode))."
        }
    }
}
