// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A protocol-bearing failure envelope for every Gnostic Call/Return error.
public struct GnosticProtocolFailure: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let reasonCode: String
    public let message: String

    public init(reasonCode: String, message: String, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.reasonCode = reasonCode
        self.message = message
    }
}

/// The single incompatible network contract implemented by this Gnostic node.
///
/// The major is deliberately explicit on every Gnostic advertisement and
/// operation payload.  It is never inferred from an object type, backend kind,
/// or an omitted field.
public enum GnosticProtocol {
    public static let currentMajor = 2

    public static func failureMessage(reasonCode: String, message: String) -> String {
        let envelope = GnosticProtocolFailure(reasonCode: reasonCode, message: message)
        let data = try! JSONEncoder().encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    public static func isCompatible(_ protocolMajor: Int?) -> Bool {
        protocolMajor == currentMajor
    }

    public static func validate(_ protocolMajor: Int?) throws {
        guard let protocolMajor else { throw GnosticProtocolError.missing }
        guard protocolMajor == currentMajor else {
            throw GnosticProtocolError.unsupported(protocolMajor)
        }
    }

    /// Validates the explicit major in a JSON object before decoding a
    /// concrete operation payload.  This keeps missing and stale majors
    /// distinguishable on Axoloty's string-only handler boundary.
    public static func validatePayload(_ parameters: String?) throws {
        guard let parameters, let data = parameters.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let major = object["protocolMajor"] as? Int else {
            throw GnosticProtocolError.missing
        }
        try validate(major)
    }

    public static func decodeMajor<K: CodingKey>(from container: KeyedDecodingContainer<K>, key: K) throws -> Int {
        let value = try container.decodeIfPresent(Int.self, forKey: key)
        try validate(value)
        return value!
    }
}

/// Stable, backend-independent interoperability capabilities.
public enum GnosticCapability {
    public static let textTurnInput = "me.atkn.gnostic.capability.turn.text"
    public static let streamedTurnUpdates = "me.atkn.gnostic.capability.turn.stream"
    public static let turnCancellation = "me.atkn.gnostic.capability.turn.cancel"
    public static let turnReplay = "me.atkn.gnostic.capability.turn.replay"
    public static let permissionMediation = "me.atkn.gnostic.capability.permission.mediation"
    public static let workspaceAttachment = "me.atkn.gnostic.capability.workspace.attach"
    public static let workspaceToolInvocation = "me.atkn.gnostic.capability.workspace.tool"

    public static let stable: Set<String> = [
        textTurnInput,
        streamedTurnUpdates,
        turnReplay,
        permissionMediation,
        workspaceAttachment,
        workspaceToolInvocation,
    ]

    /// Experimental names are intentionally namespaced.  Generic clients
    /// ignore names they do not recognize, including future stable names.
    public static func isNamespacedExperimental(_ capability: String) -> Bool {
        capability.hasPrefix("x-") && capability.contains(".")
    }
}

/// Structured protocol compatibility failures used at every direct seam.
public enum GnosticProtocolError: Error, Codable, Sendable, Equatable, LocalizedError {
    case missing
    case unsupported(Int)

    public var reasonCode: String {
        switch self {
        case .missing: "missingProtocolMajor"
        case .unsupported: "unsupportedProtocolMajor"
        }
    }

    public var statusCode: Int {
        switch self {
        case .missing: 400
        case .unsupported: 426
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missing:
            "protocolMajor is required; supported major is \(GnosticProtocol.currentMajor)."
        case let .unsupported(value):
            "protocolMajor \(value) is unsupported; supported major is \(GnosticProtocol.currentMajor)."
        }
    }

    /// A deterministic message for Axoloty's string-only Call/Return failure
    /// surface.  The response still carries the current major for clients that
    /// need to recover without guessing.
    public var failureMessage: String { GnosticProtocol.failureMessage(reasonCode: reasonCode, message: errorDescription ?? reasonCode) }

    private enum CodingKeys: String, CodingKey { case protocolMajor, reasonCode, message }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(GnosticProtocol.currentMajor, forKey: .protocolMajor)
        try container.encode(reasonCode, forKey: .reasonCode)
        try container.encode(errorDescription ?? reasonCode, forKey: .message)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reason = try container.decode(String.self, forKey: .reasonCode)
        switch reason {
        case "missingProtocolMajor": self = .missing
        case "unsupportedProtocolMajor": self = .unsupported(try container.decodeIfPresent(Int.self, forKey: .protocolMajor) ?? 0)
        default: throw DecodingError.dataCorruptedError(forKey: .reasonCode, in: container, debugDescription: "Unknown protocol error")
        }
    }
}
