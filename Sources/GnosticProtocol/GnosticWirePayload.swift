// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation

/// The payload budget shared by every Gnostic Axoloty event.
///
/// Axoloty validates the complete event payload, including its small protocol
/// envelope. Callers therefore validate the final encoded value at the
/// transport boundary instead of relying on the size of an embedded field.
public enum GnosticWirePayload {
    /// Maximum bytes accepted by the Axoloty wire configuration.
    public static let maximumBytes = WireBufferConfig.maxPayloadSize

    /// Maximum Coaty topic bytes provided by the released Axoloty wire profile.
    public static let maximumTopicBytes = WireBufferConfig.maxTopicLength

    /// A conservative application-value budget leaves room for the Axoloty
    /// event envelope when an encoded value is embedded in a Call or Channel.
    public static let maximumEmbeddedValueBytes = 1_800

    /// Shared bound for the text field in a Turn result. The same
    /// value is used while constructing and decoding results.
    public static let maximumTurnResultTextBytes = 1_400

    /// The one canonical bound for a Turn prompt. The client encoder
    /// and the serve decoder both apply it, so an accepted prompt is
    /// byte-identical on both sides. A larger prompt is rejected, never
    /// truncated. The bound leaves room inside ``maximumEmbeddedValueBytes``
    /// for the request envelope and the bounded `clientTurnID`.
    public static let maximumTurnMessageBytes = 1_400

    /// Fixed bounds for values whose source is user- or provider-controlled.
    /// Lists use a separate query/page operation when their size is not fixed.
    public static let maximumLabelBytes = 256
    public static let maximumIdentifierBytes = 128
    public static let maximumAttachedWorkspaceIDs = 32
    public static let maximumListItems = 16

    public enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case tooLarge(context: String, actualBytes: Int, maximumBytes: Int)
        case invalidIdentifier(context: String)

        public var errorDescription: String? {
            switch self {
            case let .tooLarge(context, actualBytes, maximumBytes):
                "\(context) is \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
            case let .invalidIdentifier(context):
                context
            }
        }
    }

    /// Encodes one application value and rejects values that cannot safely be
    /// embedded in a bounded Gnostic operation payload.
    public static func encode<T: Encodable>(_ value: T, context: String) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumEmbeddedValueBytes else {
            throw Error.tooLarge(context: context, actualBytes: data.count, maximumBytes: maximumEmbeddedValueBytes)
        }
        return data
    }

    /// Validates a complete Axoloty event payload after its envelope has been
    /// assembled.
    public static func validateEvent(_ data: Data, context: String) throws {
        guard data.count <= maximumBytes else {
            throw Error.tooLarge(context: context, actualBytes: data.count, maximumBytes: maximumBytes)
        }
    }

    /// Bounds a UTF-8 string without splitting a scalar. This is used only for
    /// diagnostic/status fields where retaining a prefix is preferable to
    /// allowing an otherwise valid event to overflow.
    public static func prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var result = String()
        result.reserveCapacity(maximumBytes)
        for scalar in value.unicodeScalars {
            result.unicodeScalars.append(scalar)
            if result.utf8.count > maximumBytes {
                result.unicodeScalars.removeLast()
                break
            }
        }
        return result
    }

    public static func boundedLabel(_ value: String) -> String {
        prefix(value, maximumBytes: maximumLabelBytes)
    }

    public static func boundedIdentifier(_ value: String) -> String {
        prefix(value, maximumBytes: maximumIdentifierBytes)
    }

    /// Returns the one accepted representation of a Turn prompt.
    ///
    /// The client encoder and the serve decoder share this rule. A prompt that
    /// exceeds ``maximumTurnMessageBytes`` is rejected with
    /// ``Error/tooLarge(context:actualBytes:maximumBytes:)`` instead of being
    /// truncated, so a run and its replay always digest the same bytes.
    public static func canonicalTurnMessage(
        _ value: String,
        context: String = "turn message"
    ) throws -> String {
        guard value.utf8.count <= maximumTurnMessageBytes else {
            throw Error.tooLarge(
                context: context,
                actualBytes: value.utf8.count,
                maximumBytes: maximumTurnMessageBytes
            )
        }
        return value
    }

    /// Returns the one accepted representation of a client Turn ID.
    /// Surrounding whitespace is compatibility input, not part of identity.
    /// Invalid IDs are rejected instead of being truncated.
    public static func canonicalClientTurnID(_ value: String) throws -> String {
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else {
            throw Error.invalidIdentifier(context: "clientTurnID must not be empty")
        }
        guard canonical.utf8.count <= maximumIdentifierBytes else {
            throw Error.invalidIdentifier(context: "clientTurnID exceeds the maximum of \(maximumIdentifierBytes) bytes")
        }
        return canonical
    }

    public static func boundedWorkspaceIDs(_ values: [UUID]) -> [UUID] {
        Array(values.prefix(maximumAttachedWorkspaceIDs))
    }
}
