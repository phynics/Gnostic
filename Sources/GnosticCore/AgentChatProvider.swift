// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// The wire payload for a remote `agent.chat` turn.
public struct AgentChatRequest: Codable, Sendable {
    public let message: String
    public let timelineID: UUID
    public let clientTurnID: String?

    public init(message: String, timelineID: UUID, clientTurnID: String? = nil) {
        self.message = message
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }
}

/// The wire result of a remote `agent.chat` turn.
public struct AgentChatResult: Codable, Sendable {
    public let clientTurnID: String?
    public let text: String
    public let replayed: Bool

    public init(clientTurnID: String? = nil, text: String, replayed: Bool = false) {
        self.clientTurnID = clientTurnID
        self.text = text
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case clientTurnID
        case text
        case replayed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientTurnID = try container.decodeIfPresent(String.self, forKey: .clientTurnID)
        text = try container.decode(String.self, forKey: .text)
        // Older serves returned only `{text}`. Keep that response readable while
        // new callers receive the explicit replay marker.
        replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}

/// Terminal failures retained by the serve-lifetime turn coordinator.
public enum AscendantTurnError: Error, Sendable, Equatable, LocalizedError {
    case conflict(timelineID: UUID, clientTurnID: String)
    case failed(timelineID: UUID, clientTurnID: String, detail: String)
    case cancelled(timelineID: UUID, clientTurnID: String)

    public var errorDescription: String? {
        switch self {
        case let .conflict(timelineID, clientTurnID):
            "clientTurnID \(clientTurnID) was already used with different content on Timeline \(timelineID.uuidString.lowercased())"
        case let .failed(_, _, detail):
            detail
        case let .cancelled(_, clientTurnID):
            "agent.chat turn \(clientTurnID) was cancelled"
        }
    }

    public var statusCode: Int {
        switch self {
        case .conflict: 409
        case .failed: 500
        case .cancelled: 499
        }
    }
}

/// Hosts the `me.atkn.gnostic.agent.chat` unary Call/Return operation.
///
/// A thin wire adapter: decodes an `AgentChatRequest`, invokes the injected
/// turn closure (owned by the serve runtime), and encodes the result —
/// mirroring `WorkspaceProvider`'s contract.
public struct AgentChatProvider: Sendable {
    public static let chatOperation = "me.atkn.gnostic.agent.chat"

    public typealias TurnExecutor = @Sendable (AgentChatRequest) async throws -> AgentChatResult

    private let executor: TurnExecutor

    public init(execute: @escaping TurnExecutor) {
        self.executor = execute
    }

    public func handle(parameters: String?) async throws -> CallHandlerResult {
        guard let parameters,
              let request = try? JSONDecoder().decode(AgentChatRequest.self, from: Data(parameters.utf8)) else {
            return .failure(code: 400, message: "Invalid agent.chat payload")
        }
        do {
            let result = try await executor(request)
            let encoded = try JSONEncoder().encode(result)
            return .success(result: String(decoding: encoded, as: UTF8.self))
        } catch let error as AscendantTurnError {
            return .failure(code: error.statusCode, message: error.localizedDescription)
        } catch {
            return .failure(code: 500, message: String(describing: error))
        }
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.chatOperation) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }
}
