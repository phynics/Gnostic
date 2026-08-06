// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public enum InspectError: Error, Sendable, LocalizedError {
    case malformedUUID(String)
    case notFound(String)
    case ambiguous(String, providers: [String])
    case brokerUnreachable(String)
    case connectionFailed(String)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .malformedUUID(uuid): "Invalid UUID '\(uuid)'."
        case let .notFound(uuid): "No advertised object matches '\(uuid)'."
        case let .ambiguous(uuid, providers): "Object '\(uuid)' is advertised by multiple providers: \(providers.joined(separator: ", "))."
        case let .brokerUnreachable(detail): "Could not reach the MQTT broker: \(detail)"
        case let .connectionFailed(detail): "Connection failed: \(detail)"
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
        }
    }
}

