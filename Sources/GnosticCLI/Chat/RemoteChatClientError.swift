// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Failures produced by the remote Turn client.
public enum RemoteTurnClientError: Error, Sendable, LocalizedError {
    case brokerUnreachable(String)
    case noServedAscendant
    case workspaceUnavailable
    case workspaceAmbiguous
    case timelineNotAttached
    case approvalRequired
    case toolNotAdvertised
    case invalidWorkspaceURI
    case ambiguousAscendant
    case ascendantUnavailable(UUID)
    case providerUnavailable(String)
    case timelineUnavailable(UUID)
    case timelineAmbiguous(UUID)
    case providerMismatch

    public var errorDescription: String? {
        switch self {
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case .noServedAscendant: "No served Ascendant was discovered. Start `gnostic serve` first."
        case .workspaceUnavailable: "The workspace is not currently available."
        case .workspaceAmbiguous: "The workspace is advertised by more than one provider."
        case .timelineNotAttached: "The workspace is not attached to the requested timeline."
        case .approvalRequired: "This tool requires explicit approval."
        case .toolNotAdvertised: "The requested tool is not advertised by the workspace."
        case .invalidWorkspaceURI: "The workspace advertised an invalid URI."
        case .ambiguousAscendant: "More than one Ascendant was discovered; select one explicitly."
        case let .ascendantUnavailable(id): "Ascendant \(id.uuidString.lowercased()) was not discovered."
        case let .providerUnavailable(id): "Provider \(id.lowercased()) was not discovered."
        case let .timelineUnavailable(id): "Timeline \(id.uuidString.lowercased()) was not discovered."
        case let .timelineAmbiguous(id): "Timeline \(id.uuidString.lowercased()) is advertised by more than one Node."
        case .providerMismatch: "The response came from a different provider than the addressed Node."
        }
    }

    /// Stable machine-readable code for JSON-RPC clients.
    public var gnosticCode: String {
        switch self {
        case .brokerUnreachable: "brokerUnreachable"
        case .noServedAscendant: "noServedAscendant"
        case .workspaceUnavailable: "workspaceUnavailable"
        case .workspaceAmbiguous: "workspaceAmbiguous"
        case .timelineNotAttached: "timelineNotAttached"
        case .approvalRequired: "approvalRequired"
        case .toolNotAdvertised: "toolNotAdvertised"
        case .invalidWorkspaceURI: "invalidWorkspaceURI"
        case .ambiguousAscendant: "ambiguousAscendant"
        case .ascendantUnavailable: "ascendantUnavailable"
        case .providerUnavailable: "providerUnavailable"
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .providerMismatch: "providerMismatch"
        }
    }
}
