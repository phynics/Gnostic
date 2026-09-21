// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticLettaBackend

/// The scripted behavior one fixture turn follows.
public enum LettaFixtureScript: Sendable {
    case plain(String)
    case clientTool(name: String, arguments: String, finalText: String)
    case failure(String)
    case hang
}

/// An in-process Letta server double shared by the Letta and CLI test targets.
///
/// It emulates the subset of the documented REST state machine the backend
/// uses: agent lookup/creation, conversation creation/deletion/description,
/// the client-tool approval round trip, cancellation, and health. No network
/// and no credential are involved.
public actor FixtureLettaTransport: LettaTransport {
    struct Agent {
        var id: String
        var name: String
        var metadata: ManifestJSONValue?
    }

    struct Conversation {
        var id: String
        var agentID: String
        var description: String?
        var isArchived: Bool
    }

    private var agents: [String: Agent] = [:]
    private var conversations: [String: Conversation] = [:]
    private var hangContinuations: [String: AsyncThrowingStream<LettaStreamEvent, Error>.Continuation] = [:]
    private var pendingFinalText: String?

    private let scriptForMessage: @Sendable (String) -> LettaFixtureScript
    public private(set) var cancelCount = 0
    public private(set) var hangCount = 0
    public private(set) var recordedToolReturns: [LettaToolReturn] = []
    public private(set) var recordedClientTools: [LettaClientTool] = []
    public private(set) var sentInputs: [LettaMessageInput] = []
    private var sendFailure: LettaTransportError?

    public init(scriptForMessage: @escaping @Sendable (String) -> LettaFixtureScript = { .plain("reply: \($0)") }) {
        self.scriptForMessage = scriptForMessage
    }

    public func setSendFailure(_ error: LettaTransportError?) {
        sendFailure = error
    }

    public var conversationCount: Int { conversations.count }
    public var agentCount: Int { agents.count }

    public func agentMetadata(id: String) -> ManifestJSONValue? { agents[id]?.metadata }

    public func health() async throws -> LettaHealth {
        LettaHealth(status: "ok", version: "fixture")
    }

    public func listAgents(name: String) async throws -> [LettaAgentDescriptor] {
        agents.values
            .filter { $0.name == name }
            .map { LettaAgentDescriptor(id: $0.id, name: $0.name, metadata: $0.metadata) }
    }

    public func createAgent(_ creation: LettaAgentCreation) async throws -> LettaAgentDescriptor {
        let id = "agent-\(UUID().uuidString.lowercased())"
        let agent = Agent(id: id, name: creation.name, metadata: creation.metadata)
        agents[id] = agent
        return LettaAgentDescriptor(id: id, name: agent.name, metadata: agent.metadata)
    }

    public func updateAgentMetadata(agentID: String, metadata: ManifestJSONValue) async throws {
        agents[agentID]?.metadata = metadata
    }

    public func listConversations(agentID: String) async throws -> [LettaConversationDescriptor] {
        conversations.values
            .filter { $0.agentID == agentID && !$0.isArchived }
            .map { LettaConversationDescriptor(id: $0.id, agentID: $0.agentID, description: $0.description, isArchived: $0.isArchived) }
    }

    public func createConversation(agentID: String, description: String?) async throws -> LettaConversationDescriptor {
        let id = "conv-\(UUID().uuidString.lowercased())"
        conversations[id] = Conversation(id: id, agentID: agentID, description: description, isArchived: false)
        return LettaConversationDescriptor(id: id, agentID: agentID, description: description, isArchived: false)
    }

    public func updateConversation(conversationID: String, description: String?) async throws {
        conversations[conversationID]?.description = description
    }

    public func deleteConversation(conversationID: String) async throws {
        conversations[conversationID]?.isArchived = true
    }

    public func cancelConversation(agentID: String, conversationID: String) async throws {
        cancelCount += 1
        if let continuation = hangContinuations[conversationID] {
            continuation.finish(throwing: LettaTransportError.protocolFailure("cancelled"))
            hangContinuations[conversationID] = nil
        }
    }

    public func sendMessage(
        agentID: String,
        conversationID: String,
        input: LettaMessageInput,
        clientTools: [LettaClientTool]
    ) async throws -> AsyncThrowingStream<LettaStreamEvent, Error> {
        sentInputs.append(input)
        if !clientTools.isEmpty { recordedClientTools = clientTools }
        if let sendFailure { throw sendFailure }

        switch input {
        case let .user(message):
            switch scriptForMessage(message) {
            case let .plain(text):
                return Self.scripted([.assistantText(text), .stopReason("end_turn")])
            case let .clientTool(name, arguments, finalText):
                pendingFinalText = finalText
                return Self.scripted([
                    .approvalRequest(requestID: "approval-1", toolCallID: "call-1", name: name, arguments: arguments),
                    .stopReason("requires_approval"),
                ])
            case let .failure(reason):
                return Self.scripted([.stopReason(reason)])
            case .hang:
                let (stream, continuation) = AsyncThrowingStream<LettaStreamEvent, Error>.makeStream()
                hangContinuations[conversationID] = continuation
                hangCount += 1
                return stream
            }
        case let .approvals(returns):
            recordedToolReturns.append(contentsOf: returns)
            let text = pendingFinalText ?? returns.first?.content ?? ""
            pendingFinalText = nil
            return Self.scripted([.assistantText(text), .stopReason("end_turn")])
        }
    }

    private static func scripted(_ events: [LettaStreamEvent]) -> AsyncThrowingStream<LettaStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
