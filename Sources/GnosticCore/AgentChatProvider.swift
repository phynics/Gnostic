// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// The wire payload for a remote `agent.chat` turn.
public struct AgentChatRequest: Codable, Sendable {
    public let message: String
    public let timelineID: UUID

    public init(message: String, timelineID: UUID) {
        self.message = message
        self.timelineID = timelineID
    }
}

/// The wire result of a remote `agent.chat` turn.
public struct AgentChatResult: Codable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
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