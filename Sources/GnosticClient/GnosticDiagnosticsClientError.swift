// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol

/// Failures produced by the public live-diagnostics client.
public enum GnosticDiagnosticsClientError: Error, Sendable, Equatable, LocalizedError {
    /// No live provider serves node-wide diagnostics, because none advertises a
    /// Runtime instance, or the addressed provider does not.
    ///
    /// This is the clear degradation path: a Node with no Runtime instance is
    /// refused locally without a wire call.
    case nodeUnavailable

    /// More than one live provider serves node-wide diagnostics.
    case nodeAmbiguous

    /// No live provider advertised the addressed Runtime instance, or the
    /// Runtime instance that operates the addressed Timeline is not advertised
    /// by the Timeline's provider.
    case runtimeInstanceUnavailable(UUID)

    /// More than one provider advertised the addressed Runtime instance.
    case runtimeInstanceAmbiguous(UUID)

    /// No live provider advertised the addressed Timeline, or the Timeline
    /// names no operating Runtime instance to gate against.
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
        case .nodeUnavailable: "nodeUnavailable"
        case .nodeAmbiguous: "nodeAmbiguous"
        case .runtimeInstanceUnavailable: "runtimeInstanceUnavailable"
        case .runtimeInstanceAmbiguous: "runtimeInstanceAmbiguous"
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .providerMismatch: "providerMismatch"
        case let .callFailed(reasonCode, _, _): reasonCode
        }
    }

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case .nodeUnavailable:
            "No discovered Node advertises a Runtime instance, so none serves live diagnostics."
        case .nodeAmbiguous:
            "More than one discovered Node serves live diagnostics."
        case let .runtimeInstanceUnavailable(id):
            "Runtime instance \(id.uuidString.lowercased()) was not discovered, or is not advertised by the Timeline's provider."
        case let .runtimeInstanceAmbiguous(id):
            "Runtime instance \(id.uuidString.lowercased()) is advertised by more than one provider."
        case let .timelineUnavailable(id):
            "Timeline \(id.uuidString.lowercased()) was not discovered, or names no operating Runtime instance."
        case let .timelineAmbiguous(id):
            "Timeline \(id.uuidString.lowercased()) is advertised by more than one provider."
        case .providerMismatch:
            "The provider does not own the requested target, or the response came from another provider."
        case let .callFailed(reasonCode, statusCode, _):
            "The serve rejected the diagnostics operation: \(reasonCode) (status \(statusCode))."
        }
    }
}
