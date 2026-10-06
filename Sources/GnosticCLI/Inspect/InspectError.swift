// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

public enum InspectError: Error, Sendable, LocalizedError {
    case malformedUUID(String)
    case notFound(String)
    case ambiguous(String, providers: [String])
    case brokerUnreachable(String)
    case connectionFailed(String)
    case diagnosticsCapabilityUnavailable(String)
    case diagnosticsUnavailable(String)
    case diagnosticsAmbiguous(String)
    case ascendantUnavailable(UUID)
    case timelineUnavailable(UUID)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .malformedUUID(uuid): "Invalid UUID '\(uuid)'."
        case let .notFound(uuid): "No advertised object matches '\(uuid)'."
        case let .ambiguous(uuid, providers): "Object '\(uuid)' is advertised by multiple providers: \(providers.joined(separator: ", "))."
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case let .connectionFailed(detail): "Connection failed: \(detail)"
        case let .diagnosticsCapabilityUnavailable(capability):
            "Live diagnostics are unavailable: no discovered Node advertises capability \(capability)."
        case let .diagnosticsUnavailable(detail): "Live diagnostics are unavailable: \(detail)"
        case let .diagnosticsAmbiguous(target): "Live diagnostics target '\(target)' is served by more than one provider."
        case let .ascendantUnavailable(id): "Ascendant \(id.uuidString.lowercased()) was not discovered."
        case let .timelineUnavailable(id): "Timeline \(id.uuidString.lowercased()) was not discovered."
        }
    }

    /// A machine-readable reason label for diagnostics.
    public var reasonCode: String {
        switch self {
        case .malformedUUID: "malformedUUID"
        case .notFound: "notFound"
        case .ambiguous: "ambiguous"
        case .brokerUnreachable: "brokerUnreachable"
        case .connectionFailed: "connectionFailed"
        case .diagnosticsCapabilityUnavailable: "diagnosticsCapabilityUnavailable"
        case .diagnosticsUnavailable: "diagnosticsUnavailable"
        case .diagnosticsAmbiguous: "diagnosticsAmbiguous"
        case .ascendantUnavailable: "ascendantUnavailable"
        case .timelineUnavailable: "timelineUnavailable"
        }
    }
}

extension InspectError {
    /// Maps a live-diagnostics client failure to its CLI form.
    ///
    /// - Parameter error: The client failure.
    public init(_ error: GnosticDiagnosticsClientError) {
        switch error {
        case let .missingCapability(capability): self = .diagnosticsCapabilityUnavailable(capability)
        case .nodeUnavailable: self = .diagnosticsUnavailable("no discovered Node serves live diagnostics")
        case .nodeAmbiguous: self = .diagnosticsAmbiguous("node")
        case let .ascendantUnavailable(id): self = .ascendantUnavailable(id)
        case let .ascendantAmbiguous(id): self = .diagnosticsAmbiguous(id.uuidString.lowercased())
        case let .timelineUnavailable(id): self = .timelineUnavailable(id)
        case let .timelineAmbiguous(id): self = .diagnosticsAmbiguous(id.uuidString.lowercased())
        case .providerMismatch: self = .diagnosticsUnavailable("the provider does not own the requested target")
        case let .callFailed(reasonCode, statusCode, retryable):
            self = .diagnosticsUnavailable("\(reasonCode) (status \(statusCode), retryable=\(retryable))")
        }
    }
}
