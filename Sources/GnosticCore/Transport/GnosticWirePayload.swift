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

    /// Fixed bounds for values whose source is user- or provider-controlled.
    /// Lists use a separate query/page operation when their size is not fixed.
    public static let maximumLabelBytes = 256
    public static let maximumIdentifierBytes = 128
    public static let maximumAttachedWorkspaceIDs = 32
    public static let maximumListItems = 16

    public enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case tooLarge(context: String, actualBytes: Int, maximumBytes: Int)

        public var errorDescription: String? {
            switch self {
            case let .tooLarge(context, actualBytes, maximumBytes):
                "\(context) is \(actualBytes) bytes; the maximum is \(maximumBytes) bytes."
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

    public static func boundedWorkspaceIDs(_ values: [UUID]) -> [UUID] {
        Array(values.prefix(maximumAttachedWorkspaceIDs))
    }
}
