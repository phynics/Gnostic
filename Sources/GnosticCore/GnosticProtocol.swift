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
    public static let currentMajor = 2

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
        var data = (try? JSONEncoder().encode(envelope)) ?? Data(#"{"protocolMajor":2,"reasonCode":"internalError","message":"Internal error"}"#.utf8)
        if data.count > GnosticWirePayload.maximumEmbeddedValueBytes {
            envelope = GnosticProtocolFailure(reasonCode: "payloadTooLarge", message: "The response was too large to send.")
            data = (try? JSONEncoder().encode(envelope)) ?? Data(#"{"protocolMajor":2,"reasonCode":"payloadTooLarge","message":"The response was too large to send."}"#.utf8)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Maps an error to a bounded public failure without exposing arbitrary
    /// implementation details from an injected executor or transport.
    ///
    /// Structured domain failures retain their established status and reason
    /// code. Unknown failures use the supplied safe fallback message.
    public static func publicFailure(
        for error: Error,
        fallbackCode: Int,
        fallbackReasonCode: String,
        fallbackMessage: String
    ) -> GnosticPublicFailure {
        if let error = error as? GnosticProtocolError {
            return GnosticPublicFailure(code: error.statusCode, message: error.failureMessage)
        }
        if let error = error as? NodeRuntimeError {
            return GnosticPublicFailure(
                code: error.statusCode,
                message: failureMessage(reasonCode: error.reasonCode, message: error.publicMessage, statusCode: error.statusCode),
                retryable: false
            )
        }
        if let error = error as? AscendantTurnError {
            return GnosticPublicFailure(
                code: error.statusCode,
                message: failureMessage(reasonCode: error.reasonCode, message: error.publicMessage, statusCode: error.statusCode, retryable: error.retryable),
                retryable: error.retryable
            )
        }
        if let error = error as? AscendantBackendError {
            return GnosticPublicFailure(
                code: error.statusCode,
                message: failureMessage(reasonCode: error.reasonCode, message: backendPublicMessage(for: error), statusCode: error.statusCode),
                retryable: false
            )
        }
        if let error = error as? DiscoveredWorkspaceAttachmentError {
            switch error {
            case .approvalRequired:
                return GnosticPublicFailure(code: 403, message: failureMessage(reasonCode: "approvalRequired", message: "Workspace attachment requires approval."))
            case let .unavailable(status):
                return GnosticPublicFailure(code: 409, message: failureMessage(reasonCode: "workspaceUnavailable", message: "Workspace is not uniquely available (\(status))."))
            case .invalidURI:
                return GnosticPublicFailure(code: 422, message: failureMessage(reasonCode: "invalidWorkspaceURI", message: "Workspace advertised an invalid URI."))
            case let .timelineNotOwned(id):
                return GnosticPublicFailure(code: 404, message: failureMessage(reasonCode: "timelineNotOwned", message: "Timeline \(id.uuidString.lowercased()) is not owned by this Node."))
            }
        }
        return GnosticPublicFailure(code: fallbackCode, message: failureMessage(reasonCode: fallbackReasonCode, message: fallbackMessage, statusCode: fallbackCode))
    }

    private static func backendPublicMessage(for error: AscendantBackendError) -> String {
        switch error {
        case .invalidConfiguration:
            "The Ascendant backend configuration is invalid."
        case .timelineNotFound:
            "The Timeline was not found."
        case .terminal:
            "The Ascendant backend reported a terminal failure."
        case .cancelled:
            "The Ascendant turn was cancelled."
        case .lifecycleUnusable:
            "The Ascendant backend lifecycle is unavailable."
        }
    }

    static func boundedStatusCode(_ value: Int) -> Int {
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
