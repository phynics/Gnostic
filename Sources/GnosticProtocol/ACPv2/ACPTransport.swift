// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Protocol for ACP transport layers (e.g., process stdio, WebSocket, in-memory).
public protocol ACPTransport: Sendable {
    var messages: AsyncStream<ACPJSONRPCMessage> { get }
    func start() async throws
    func send(_ message: ACPJSONRPCMessage) async throws
    func close() async
}

/// Errors raised by ACP transports or connection layers.
public enum ACPTransportError: Error, LocalizedError, Equatable, Sendable {
    case transportClosed
    case timeout
    case responseMismatch
    case unexpectedMessage

    public var errorDescription: String? {
        switch self {
        case .transportClosed: return "The ACP transport is closed."
        case .timeout: return "The ACP transport timed out waiting for a response."
        case .responseMismatch: return "Response ID did not match the request."
        case .unexpectedMessage: return "Unexpected ACP message received."
        }
    }
}

/// Empty response payload for void methods.
public struct ACPEmptyResponse: Codable, Sendable, Equatable {
    public init() {}
}
