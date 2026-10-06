// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A JSON value used by backend-owned manifest settings.
public enum ManifestJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ManifestJSONValue])
    case array([ManifestJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode([String: ManifestJSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([ManifestJSONValue].self) { self = .array(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var encodedByteCount: Int {
        (try? JSONEncoder().encode(self).count) ?? Int.max
    }

    public var maximumDepth: Int {
        switch self {
        case .string, .number, .bool, .null: return 1
        case let .object(values): return 1 + (values.values.map(\.maximumDepth).max() ?? 0)
        case let .array(values): return 1 + (values.map(\.maximumDepth).max() ?? 0)
        }
    }

    public var entryCount: Int {
        switch self {
        case .string, .number, .bool, .null: return 1
        case let .object(values): return values.count + values.values.reduce(0) { $0 + $1.entryCount }
        case let .array(values): return values.count + values.reduce(0) { $0 + $1.entryCount }
        }
    }
}
