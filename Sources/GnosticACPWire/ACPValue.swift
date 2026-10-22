// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A lossless Codable value representation for dynamic JSON data in ACP v2.
/// Used to preserve unknown enum values, extension fields prefixed with `_`,
/// and untyped metadata dictionaries through serialization and deserialization.
public enum ACPValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: ACPValue])
    case array([ACPValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
            return
        }
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
            return
        }
        if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
            return
        }
        if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
            return
        }
        if let arrayVal = try? container.decode([ACPValue].self) {
            self = .array(arrayVal)
            return
        }
        if let objectVal = try? container.decode([String: ACPValue].self) {
            self = .object(objectVal)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported ACP JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case let .string(v) = self else { return nil }
        return v
    }

    public var intValue: Int? {
        guard case let .int(v) = self else { return nil }
        return v
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(v): return Double(v)
        case let .double(v): return v
        default: return nil
        }
    }

    public var boolValue: Bool? {
        guard case let .bool(v) = self else { return nil }
        return v
    }

    public var objectValue: [String: ACPValue]? {
        guard case let .object(v) = self else { return nil }
        return v
    }

    public var arrayValue: [ACPValue]? {
        guard case let .array(v) = self else { return nil }
        return v
    }

    public subscript(key: String) -> ACPValue? {
        guard case let .object(dict) = self else { return nil }
        return dict[key]
    }

    public static func boolean(_ value: Bool) -> ACPValue {
        .bool(value)
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension ACPValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension ACPValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension ACPValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension ACPValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension ACPValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, ACPValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension ACPValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: ACPValue...) {
        self = .array(elements)
    }
}

extension ACPValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}
