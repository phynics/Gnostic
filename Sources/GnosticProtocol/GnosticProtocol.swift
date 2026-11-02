// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A protocol-bearing failure envelope for every Gnostic Call/Return error.
public struct GnosticProtocolFailure: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let reasonCode: String
    public let message: String
    public let statusCode: Int
    public let retryable: Bool

    public init(
        reasonCode: String,
        message: String,
        statusCode: Int = 500,
        retryable: Bool = false,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.reasonCode = reasonCode
        self.message = message
        self.statusCode = GnosticProtocol.boundedStatusCode(statusCode)
        self.retryable = retryable
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, reasonCode, message, statusCode, retryable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try container.decode(Int.self, forKey: .protocolMajor)
        reasonCode = try container.decode(String.self, forKey: .reasonCode)
        message = try container.decode(String.self, forKey: .message)
        statusCode = GnosticProtocol.boundedStatusCode(try container.decodeIfPresent(Int.self, forKey: .statusCode) ?? 500)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
    }
}

/// A safe failure ready for the Axoloty Call/Return boundary.
public struct GnosticPublicFailure: Sendable, Equatable {
    public let code: Int
    public let message: String

    public let retryable: Bool

    public init(code: Int, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// The single incompatible network contract implemented by this Gnostic node.
///
/// The major is deliberately explicit on every Gnostic advertisement and
/// operation payload.  It is never inferred from an object type, backend kind,
/// or an omitted field.
public enum GnosticProtocol {
    public static let currentMajor = 3

    public static func failureMessage(
        reasonCode: String,
        message: String,
        statusCode: Int = 500,
        retryable: Bool = false
    ) -> String {
        var envelope = GnosticProtocolFailure(
            reasonCode: GnosticWirePayload.boundedIdentifier(reasonCode),
            message: GnosticWirePayload.boundedLabel(message),
            statusCode: statusCode,
            retryable: retryable
        )
        var data = (try? JSONEncoder().encode(envelope)) ?? Data(#"{"protocolMajor":3,"reasonCode":"internalError","message":"Internal error"}"#.utf8)
        if data.count > GnosticWirePayload.maximumEmbeddedValueBytes {
            envelope = GnosticProtocolFailure(reasonCode: "payloadTooLarge", message: "The response was too large to send.")
            data = (try? JSONEncoder().encode(envelope)) ?? Data(#"{"protocolMajor":3,"reasonCode":"payloadTooLarge","message":"The response was too large to send."}"#.utf8)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Bounds a status code to the HTTP range the wire contract accepts.
    ///
    /// A value outside `100...599` becomes `500`, so a malformed peer status
    /// cannot escape the protocol envelope.
    public static func boundedStatusCode(_ value: Int) -> Int {
        guard (100...599).contains(value) else { return 500 }
        return value
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

/// Stable capability names a client can require from a Runtime instance.
///
/// A Node advertises no capability list (ADR 0020 §8). A Runtime instance
/// provides the names in ``providedByRuntimeInstance`` by being advertised, so a
/// client checks that the operating instance is present instead of reading a
/// list. The other names stay as vocabulary for ``InteroperabilityCapability``.
public enum GnosticCapability {
    public static let textTurnInput = InteroperabilityCapability.textTurn.rawValue
    public static let streamedTurnUpdates = InteroperabilityCapability.streamedUpdates.rawValue
    public static let turnCancellation = InteroperabilityCapability.cancellation.rawValue
    public static let turnReplay = InteroperabilityCapability.replay.rawValue
    public static let permissionMediation = InteroperabilityCapability.permissionMediation.rawValue
    public static let timelineManagement = InteroperabilityCapability.timelineManagement.rawValue
    public static let workspaceAttachment = InteroperabilityCapability.workspaceAttachment.rawValue
    public static let workspaceToolInvocation = InteroperabilityCapability.workspaceToolInvocation.rawValue
    public static let diagnostics = InteroperabilityCapability.diagnostics.rawValue

    /// The capabilities every advertised Runtime instance provides.
    ///
    /// - ``textTurnInput``: ACP v2 requires `session/prompt`.
    /// - ``timelineManagement``: the hosting Node owns Timeline creation and
    ///   renaming.
    /// - ``diagnostics``: the hosting Node serves payload-free diagnostics. A
    ///   provider offers diagnostics when it advertises at least one Runtime
    ///   instance at the current protocol major; a Node with no advertised
    ///   instance has nothing to diagnose and offers none.
    public static let providedByRuntimeInstance: Set<String> = [
        textTurnInput,
        timelineManagement,
        diagnostics,
    ]

    public static let stable: Set<String> = [
        textTurnInput,
        streamedTurnUpdates,
        turnReplay,
        permissionMediation,
        timelineManagement,
        workspaceAttachment,
        workspaceToolInvocation,
        diagnostics,
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
    public var failureMessage: String { GnosticProtocol.failureMessage(reasonCode: reasonCode, message: errorDescription ?? reasonCode, statusCode: statusCode) }

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
