// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared

/// A JSON-RPC 2.0 request identifier.
public enum JSONRPCIdentifier: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Int64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Int64.self) {
            self = .number(number)
        } else {
            throw JSONRPCProtocolError.invalidRequest
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        }
    }
}

/// Standard JSON-RPC error codes used by the bridge.
public enum JSONRPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case invalidState = -32001
}

/// A JSON-RPC error object.
public struct JSONRPCErrorObject: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Errors raised while decoding a JSON-RPC envelope or frame.
public enum JSONRPCProtocolError: Error, Equatable, Sendable {
    case invalidRequest
    case incompleteFrame
}

/// A JSON-RPC 2.0 request or notification.
public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCIdentifier?
    public let method: String
    public let params: AnyCodable?

    public init(
        id: JSONRPCIdentifier?,
        method: String,
        params: AnyCodable? = nil
    ) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == "2.0",
              let method = try container.decodeIfPresent(String.self, forKey: .method),
              !method.isEmpty else {
            throw JSONRPCProtocolError.invalidRequest
        }
        jsonrpc = "2.0"
        id = try container.decodeIfPresent(JSONRPCIdentifier.self, forKey: .id)
        self.method = method
        params = try container.decodeIfPresent(AnyCodable.self, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id { try container.encode(id, forKey: .id) }
        try container.encode(method, forKey: .method)
        if let params { try container.encode(params, forKey: .params) }
    }
}

/// A JSON-RPC 2.0 success or error response.
public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCIdentifier?
    public let result: AnyCodable?
    public let error: JSONRPCErrorObject?

    public init(id: JSONRPCIdentifier?, result: AnyCodable) {
        jsonrpc = "2.0"
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: JSONRPCIdentifier?, error: JSONRPCErrorObject) {
        jsonrpc = "2.0"
        self.id = id
        result = nil
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .jsonrpc) == "2.0" else {
            throw JSONRPCProtocolError.invalidRequest
        }
        id = try container.decodeIfPresent(JSONRPCIdentifier.self, forKey: .id)
        result = try container.decodeIfPresent(AnyCodable.self, forKey: .result)
        error = try container.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
        guard (result == nil) != (error == nil) else {
            throw JSONRPCProtocolError.invalidRequest
        }
        jsonrpc = "2.0"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        if let id { try container.encode(id, forKey: .id) }
        if let result { try container.encode(result, forKey: .result) }
        if let error { try container.encode(error, forKey: .error) }
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }
}

/// A byte-level LF-delimited JSON-RPC frame decoder.
public struct LFMessageFramer: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// Appends bytes and returns complete frames without their LF delimiter.
    public mutating func append(_ data: Data) -> [Data] {
        pending.append(contentsOf: data)
        var frames: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            frames.append(Data(pending[..<newline]))
            pending.removeFirst(newline + 1)
        }
        return frames
    }

    /// Fails when EOF arrives in the middle of a JSON-RPC frame.
    public mutating func finish() throws {
        guard pending.isEmpty else { throw JSONRPCProtocolError.incompleteFrame }
    }
}
