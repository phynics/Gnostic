// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Failures produced by the public workspace client.
public enum GnosticWorkspaceClientError: Error, Sendable, Equatable, LocalizedError {
    /// Attachment is a user-approved operation and approval was not supplied.
    case approvalRequired

    /// No live provider uniquely advertises the addressed Workspace as available.
    case workspaceUnavailable(UUID)

    /// More than one provider advertises the addressed Workspace.
    case workspaceAmbiguous(UUID)

    /// The addressed Workspace is advertised but cannot be safely used.
    case workspaceUnsupported(UUID)

    /// No live provider advertised the addressed Timeline.
    case timelineUnavailable(UUID)

    /// More than one provider advertised the addressed Timeline.
    case timelineAmbiguous(UUID)

    /// The addressed provider does not own the target, or the response came
    /// from a different provider than the addressed one.
    case providerMismatch

    /// The resolved provider does not advertise the required capability.
    case missingCapability(String)

    /// The serve rejected the operation with a structured protocol failure.
    ///
    /// `reasonCode` is the serve's stable code, `statusCode` its HTTP-like
    /// status, and `retryable` whether the serve marked the failure retryable.
    case callFailed(reasonCode: String, statusCode: Int, retryable: Bool)

    /// A stable, machine-readable reason label.
    public var reasonCode: String {
        switch self {
        case .approvalRequired: "approvalRequired"
        case .workspaceUnavailable: "workspaceUnavailable"
        case .workspaceAmbiguous: "workspaceAmbiguous"
        case .workspaceUnsupported: "workspaceUnsupported"
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
        case .approvalRequired:
            "Workspace attachment requires explicit approval."
        case let .workspaceUnavailable(id):
            "Workspace \(id.uuidString.lowercased()) is not uniquely available."
        case let .workspaceAmbiguous(id):
            "Workspace \(id.uuidString.lowercased()) is advertised by more than one provider."
        case let .workspaceUnsupported(id):
            "Workspace \(id.uuidString.lowercased()) cannot be safely used."
        case let .timelineUnavailable(id):
            "Timeline \(id.uuidString.lowercased()) was not discovered."
        case let .timelineAmbiguous(id):
            "Timeline \(id.uuidString.lowercased()) is advertised by more than one provider."
        case .providerMismatch:
            "The provider does not own the requested target, or the response came from another provider."
        case let .missingCapability(capability):
            "The selected provider does not advertise capability \(capability)."
        case let .callFailed(reasonCode, statusCode, _):
            "The serve rejected the operation: \(reasonCode) (status \(statusCode))."
        }
    }
}
