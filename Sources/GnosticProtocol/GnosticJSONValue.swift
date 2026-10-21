// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A Gnostic-owned, Codable JSON value used at protocol boundaries.
///
/// The type mirrors the JSON data model without depending on a backend package:
/// it retains signed and unsigned integers exactly, keeps floating-point numbers
/// distinct, and preserves object and array structure. ACP requests, responses,
/// notifications, and error data use this value so the frontend stays free of
/// provider-specific wire types.
public enum GnosticJSONValue: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case string(String)
    /// A signed JSON integer, retained exactly through decoding and encoding.
    case integer(Int64)
    /// An unsigned JSON integer too large for `Int64`, retained exactly through decoding and encoding.
    case unsignedInteger(UInt64)
    /// A floating-point JSON number.
    case number(Double)
    case boolean(Bool)
    case dictionary([String: GnosticJSONValue])
    case array([GnosticJSONValue])
    case null

    public var description: String {
        switch self {
        case let .string(value): return value
        case let .integer(value): return String(value)
        case let .unsignedInteger(value): return String(value)
        case let .number(value): return String(value)
        case let .boolean(value): return String(value)
        case let .dictionary(value): return String(describing: value)
        case let .array(value): return String(describing: value)
        case .null: return "null"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: GnosticJSONValue].self) {
            self = .dictionary(value)
        } else if let value = try? container.decode([GnosticJSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .dictionary(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension GnosticJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension GnosticJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .integer(Int64(value))
    }
}

extension GnosticJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension GnosticJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}
