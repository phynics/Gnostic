// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol

/// Failures produced by the public live-diagnostics client.
public enum GnosticDiagnosticsClientError: Error, Sendable, Equatable, LocalizedError {
    /// The resolved provider does not advertise the required capability.
    ///
    /// This is the clear degradation path: a Node without the diagnostics
    /// capability is refused locally without a wire call.
    case missingCapability(String)

    /// No live provider serves node-wide diagnostics.
    case nodeUnavailable

    /// More than one live provider serves node-wide diagnostics.
    case nodeAmbiguous

    /// No live provider advertised the addressed Ascendant.
    case ascendantUnavailable(UUID)

    /// More than one provider advertised the addressed Ascendant.
    case ascendantAmbiguous(UUID)

    /// No live provider advertised the addressed Timeline, or the Timeline
    /// names no operating Ascendant to gate against.
    case timelineUnavailable(UUID)

    /// More than one provider advertised the addressed Timeline.
    case timelineAmbiguous(UUID)

    /// The addressed provider does not own the target, or the response came
    /// from a different provider than the addressed one.
    case providerMismatch

    /// The serve rejected the operation with a structured protocol failure.
    ///
    /// `reasonCode` is the serve's stable code, `statusCode` its HTTP-like
    /// status, and `retryable` whether the serve marked the failure retryable.
    case callFailed(reasonCode: String, statusCode: Int, retryable: Bool)

    /// A stable, machine-readable reason label.
    public var reasonCode: String {
        switch self {
        case .missingCapability: "missingCapability"
        case .nodeUnavailable: "nodeUnavailable"
        case .nodeAmbiguous: "nodeAmbiguous"
        case .ascendantUnavailable: "ascendantUnavailable"
        case .ascendantAmbiguous: "ascendantAmbiguous"
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .providerMismatch: "providerMismatch"
        case let .callFailed(reasonCode, _, _): reasonCode
        }
    }

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .missingCapability(capability):
            "The selected provider does not advertise capability \(capability)."
        case .nodeUnavailable:
            "No discovered Node serves live diagnostics."
        case .nodeAmbiguous:
            "More than one discovered Node serves live diagnostics."
        case let .ascendantUnavailable(id):
            "Ascendant \(id.uuidString.lowercased()) was not discovered."
        case let .ascendantAmbiguous(id):
            "Ascendant \(id.uuidString.lowercased()) is advertised by more than one provider."
        case let .timelineUnavailable(id):
            "Timeline \(id.uuidString.lowercased()) was not discovered, or names no operating Ascendant."
        case let .timelineAmbiguous(id):
            "Timeline \(id.uuidString.lowercased()) is advertised by more than one provider."
        case .providerMismatch:
            "The provider does not own the requested target, or the response came from another provider."
        case let .callFailed(reasonCode, statusCode, _):
            "The serve rejected the diagnostics operation: \(reasonCode) (status \(statusCode))."
        }
    }
}
