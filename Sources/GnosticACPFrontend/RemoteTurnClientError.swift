// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Failures produced by the remote Turn client.
public enum RemoteTurnClientError: Error, Sendable, LocalizedError {
    case brokerUnreachable(String)
    case noServedAscendant
    case noRuntime
    case workspaceUnavailable
    case workspaceAmbiguous
    case timelineNotAttached
    case approvalRequired
    case toolNotAdvertised
    case invalidWorkspaceURI
    case ambiguousAscendant
    case ambiguousRuntime
    case ascendantUnavailable(UUID)
    case runtimeUnavailable(UUID)
    case providerUnavailable(String)
    case providerOffline(String)
    case nodeUnavailable(UUID)
    case timelineUnavailable(UUID)
    case timelineAmbiguous(UUID)
    case providerMismatch
    case missingCapability(String)
    case promptTooLarge
    /// The Timeline has an active Turn, so Gnostic rejected this one before it
    /// reached the Runtime. The prompt was not queued and not inserted.
    case timelineBusy
    /// The Runtime did not confirm whether it inserted the prompt, and Gnostic
    /// does not send it again.
    case insertionUnknown

    public var errorDescription: String? {
        switch self {
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case .noServedAscendant: "No served Ascendant was discovered. Start `gnostic serve` first."
        case .noRuntime: "No Runtime instance was discovered. Start `gnostic serve` first."
        case .workspaceUnavailable: "The workspace is not currently available."
        case .workspaceAmbiguous: "The workspace is advertised by more than one provider."
        case .timelineNotAttached: "The workspace is not attached to the requested timeline."
        case .approvalRequired: "This tool requires explicit approval."
        case .toolNotAdvertised: "The requested tool is not advertised by the workspace."
        case .invalidWorkspaceURI: "The workspace advertised an invalid URI."
        case .ambiguousAscendant: "More than one Ascendant was discovered; select one explicitly."
        case .ambiguousRuntime: "More than one Runtime instance was discovered; select one explicitly."
        case let .ascendantUnavailable(id): "Ascendant \(id.uuidString.lowercased()) was not discovered."
        case let .runtimeUnavailable(id): "Runtime instance \(id.uuidString.lowercased()) was not discovered."
        case let .providerUnavailable(id): "Provider \(id.lowercased()) was not discovered."
        case let .providerOffline(id): "Provider \(id.lowercased()) went offline."
        case let .nodeUnavailable(id): "Node \(id.uuidString.lowercased()) was not discovered."
        case let .timelineUnavailable(id): "Timeline \(id.uuidString.lowercased()) was not discovered."
        case let .timelineAmbiguous(id): "Timeline \(id.uuidString.lowercased()) is advertised by more than one Node."
        case .providerMismatch: "The response came from a different provider than the addressed Node."
        case let .missingCapability(capability): "The selected Runtime instance does not advertise capability \(capability)."
        case .promptTooLarge:
            "The prompt exceeds the maximum size the Turn wire accepts. Shorten it and retry."
        case .timelineBusy: "Timeline is busy"
        case .insertionUnknown:
            "The Runtime did not confirm whether it inserted the prompt, and Gnostic does not send it again."
        }
    }

    /// Stable machine-readable code for JSON-RPC clients.
    public var gnosticCode: String {
        switch self {
        case .brokerUnreachable: "brokerUnreachable"
        case .noServedAscendant: "noServedAscendant"
        case .noRuntime: "noRuntime"
        case .workspaceUnavailable: "workspaceUnavailable"
        case .workspaceAmbiguous: "workspaceAmbiguous"
        case .timelineNotAttached: "timelineNotAttached"
        case .approvalRequired: "approvalRequired"
        case .toolNotAdvertised: "toolNotAdvertised"
        case .invalidWorkspaceURI: "invalidWorkspaceURI"
        case .ambiguousAscendant: "ambiguousAscendant"
        case .ambiguousRuntime: "ambiguousRuntime"
        case .ascendantUnavailable: "ascendantUnavailable"
        case .runtimeUnavailable: "runtimeUnavailable"
        case .providerUnavailable: "providerUnavailable"
        case .providerOffline: "providerOffline"
        case .nodeUnavailable: "nodeUnavailable"
        case .timelineUnavailable: "timelineUnavailable"
        case .timelineAmbiguous: "timelineAmbiguous"
        case .providerMismatch: "providerMismatch"
        case .missingCapability: "missingCapability"
        case .promptTooLarge: "promptTooLarge"
        case .timelineBusy: "timelineBusy"
        case .insertionUnknown: "insertionUnknown"
        }
    }
}
