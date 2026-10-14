// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import PKContracts

/// The single JSON value bridge for the bundled Positronic backend.
///
/// Every conversion between the Gnostic-owned ``ManifestJSONValue`` and the
/// PositronicKit `AnyCodable`/`Any` forms routes through this type: the
/// Ascendant adapter, the network invoker, and the attached Workspace proxy.
/// Before this bridge existed the mapping was copied five times and the copies
/// diverged; the adapter copy returned `.null` for `Int64`, `UInt64`, and
/// `Float` values.
///
/// ``ManifestJSONValue`` has no integer case, so `Int`, `Int64`, `UInt64`, and
/// `Float` all project onto `.number(Double(_:))`. Values inside the exact
/// integer range of `Double` (through 2^53) round-trip exactly; larger 64-bit
/// integers are rounded by the JSON contract itself, not by this bridge.
enum PositronicJSONValueBridge {
    /// Converts an unwrapped PositronicKit value into the Gnostic JSON value.
    ///
    /// - Parameter value: An `AnyCodable.value` or a nested value.
    /// - Returns: The equivalent JSON value; `.null` for a value that is not
    ///   JSON-representable.
    static func manifestValue(_ value: Any) -> ManifestJSONValue {
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .number(Double(value)) }
        if let value = value as? Int8 { return .number(Double(value)) }
        if let value = value as? Int16 { return .number(Double(value)) }
        if let value = value as? Int32 { return .number(Double(value)) }
        if let value = value as? Int64 { return .number(Double(value)) }
        if let value = value as? UInt { return .number(Double(value)) }
        if let value = value as? UInt8 { return .number(Double(value)) }
        if let value = value as? UInt16 { return .number(Double(value)) }
        if let value = value as? UInt32 { return .number(Double(value)) }
        if let value = value as? UInt64 { return .number(Double(value)) }
        if let value = value as? Float { return .number(Double(value)) }
        if let value = value as? Double { return .number(value) }
        if let value = value as? [String: AnyCodable] {
            return .object(value.mapValues { manifestValue($0.value) })
        }
        if let value = value as? [AnyCodable] {
            return .array(value.map { manifestValue($0.value) })
        }
        if let value = value as? [String: Any] {
            return .object(value.mapValues(manifestValue))
        }
        if let value = value as? [Any] {
            return .array(value.map(manifestValue))
        }
        return .null
    }

    /// Converts a PositronicKit value into the Gnostic JSON value.
    ///
    /// - Parameter value: The PositronicKit value.
    /// - Returns: The equivalent JSON value.
    static func manifestValue(_ value: AnyCodable) -> ManifestJSONValue {
        manifestValue(value.value)
    }

    /// Converts a Gnostic JSON value into the PositronicKit value.
    ///
    /// - Parameter value: The Gnostic JSON value.
    /// - Returns: The equivalent PositronicKit value.
    static func anyCodable(_ value: ManifestJSONValue) -> AnyCodable {
        switch value {
        case let .string(value): return .string(value)
        case let .number(value): return .number(value)
        case let .bool(value): return .boolean(value)
        case let .object(value): return .dictionary(value.mapValues(anyCodable))
        case let .array(value): return .array(value.map(anyCodable))
        case .null: return .null
        }
    }
}
