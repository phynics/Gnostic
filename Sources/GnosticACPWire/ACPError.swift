// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Errors encountered during ACP v2 protocol processing or transport.
public enum ACPError: Error, LocalizedError, Equatable, Sendable {
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case requestCancelled(String)
    case timelineBusy(message: String = "Timeline is busy", retryable: Bool = true)
    case unsupportedProtocolVersion(String)
    case custom(code: Int, message: String, data: ACPValue? = nil)

    public var errorCode: Int {
        switch self {
        case .parseError: return ACPv2Protocol.ErrorCode.parseError
        case .invalidRequest: return ACPv2Protocol.ErrorCode.invalidRequest
        case .methodNotFound: return ACPv2Protocol.ErrorCode.methodNotFound
        case .invalidParams: return ACPv2Protocol.ErrorCode.invalidParams
        case .internalError: return ACPv2Protocol.ErrorCode.internalError
        case .requestCancelled: return ACPv2Protocol.ErrorCode.requestCancelled
        case .timelineBusy: return ACPv2Protocol.ErrorCode.timelineBusy
        case .unsupportedProtocolVersion: return ACPv2Protocol.ErrorCode.unsupportedProtocolVersion
        case let .custom(code, _, _): return code
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .parseError(msg): return "Parse error: \(msg)"
        case let .invalidRequest(msg): return "Invalid request: \(msg)"
        case let .methodNotFound(msg): return "Method not found: \(msg)"
        case let .invalidParams(msg): return "Invalid params: \(msg)"
        case let .internalError(msg): return "Internal error: \(msg)"
        case let .requestCancelled(msg): return "Request cancelled: \(msg)"
        case let .timelineBusy(msg, _): return msg
        case let .unsupportedProtocolVersion(msg): return msg
        case let .custom(_, msg, _): return msg
        }
    }

    public var errorData: ACPValue? {
        switch self {
        case let .timelineBusy(_, retryable):
            return .object([
                "code": .string("timelineBusy"),
                "retryable": .bool(retryable)
            ])
        case let .custom(_, _, data):
            return data
        default:
            return nil
        }
    }

    public func toJSONRPCError() -> ACPJSONRPCError {
        ACPJSONRPCError(code: errorCode, message: errorDescription ?? "Unknown error", data: errorData)
    }
}
