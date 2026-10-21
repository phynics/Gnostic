// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A JSON-RPC 2.0 Request ID, which may be a string, integer, or null.
public enum ACPRequestId: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
            return
        }
        if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "ACPRequestId must be string, integer, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(val): try container.encode(val)
        case let .int(val): try container.encode(val)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case let .string(s): return s
        case let .int(i): return String(i)
        case .null: return nil
        }
    }
}

extension ACPRequestId: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension ACPRequestId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

/// JSON-RPC 2.0 Error object.
public struct ACPJSONRPCError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: ACPValue?

    public init(code: Int, message: String, data: ACPValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Standard JSON-RPC 2.0 Request.
public struct ACPJSONRPCRequest: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: ACPRequestId
    public let method: String
    public let params: ACPValue?

    public init(id: ACPRequestId, method: String, params: ACPValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Standard JSON-RPC 2.0 Response.
public struct ACPJSONRPCResponse: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: ACPRequestId
    public let result: ACPValue?
    public let error: ACPJSONRPCError?

    public init(id: ACPRequestId, result: ACPValue?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: ACPRequestId, error: ACPJSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// Standard JSON-RPC 2.0 Notification.
public struct ACPJSONRPCNotification: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: ACPValue?

    public init(method: String, params: ACPValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

/// Discriminated top-level JSON-RPC 2.0 message.
public enum ACPJSONRPCMessage: Codable, Sendable, Equatable {
    case request(ACPJSONRPCRequest)
    case response(ACPJSONRPCResponse)
    case notification(ACPJSONRPCNotification)

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idPresent = container.contains(.id)
        let method = try container.decodeIfPresent(String.self, forKey: .method)

        if let method {
            if idPresent {
                let id = try container.decode(ACPRequestId.self, forKey: .id)
                let params = try container.decodeIfPresent(ACPValue.self, forKey: .params)
                self = .request(ACPJSONRPCRequest(id: id, method: method, params: params))
            } else {
                let params = try container.decodeIfPresent(ACPValue.self, forKey: .params)
                self = .notification(ACPJSONRPCNotification(method: method, params: params))
            }
        } else if idPresent {
            let id = try container.decode(ACPRequestId.self, forKey: .id)
            let result = try container.decodeIfPresent(ACPValue.self, forKey: .result)
            let error = try container.decodeIfPresent(ACPJSONRPCError.self, forKey: .error)
            if let error {
                self = .response(ACPJSONRPCResponse(id: id, error: error))
            } else {
                self = .response(ACPJSONRPCResponse(id: id, result: result))
            }
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Malformed JSON-RPC message: neither valid request, notification, nor response."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .request(req):
            try req.encode(to: encoder)
        case let .response(resp):
            try resp.encode(to: encoder)
        case let .notification(notif):
            try notif.encode(to: encoder)
        }
    }
}
