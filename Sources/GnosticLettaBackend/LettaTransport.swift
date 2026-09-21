// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// The result of a Letta server liveness check.
public struct LettaHealth: Sendable, Equatable {
    public let status: String
    public let version: String?

    public init(status: String, version: String? = nil) {
        self.status = status
        self.version = version
    }

    public var isUsable: Bool { status.lowercased() == "ok" || status.lowercased() == "healthy" }
}

/// The Letta agent fields the backend projects after creation or lookup.
public struct LettaAgentDescriptor: Sendable, Equatable {
    public let id: String
    public let name: String
    public let metadata: ManifestJSONValue?

    public init(id: String, name: String, metadata: ManifestJSONValue? = nil) {
        self.id = id
        self.name = name
        self.metadata = metadata
    }
}

/// The fields the backend supplies when it creates a Letta agent.
public struct LettaAgentCreation: Sendable, Equatable {
    public let name: String
    public let description: String?
    public let model: String?
    public let metadata: ManifestJSONValue?

    public init(name: String, description: String? = nil, model: String? = nil, metadata: ManifestJSONValue? = nil) {
        self.name = name
        self.description = description
        self.model = model
        self.metadata = metadata
    }
}

/// The Letta conversation fields the backend projects.
public struct LettaConversationDescriptor: Sendable, Equatable {
    public let id: String
    public let agentID: String
    public let description: String?
    public let isArchived: Bool

    public init(id: String, agentID: String, description: String? = nil, isArchived: Bool = false) {
        self.id = id
        self.agentID = agentID
        self.description = description
        self.isArchived = isArchived
    }
}

/// One client-side tool offered to a Letta turn.
public struct LettaClientTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: ManifestJSONValue

    public init(name: String, description: String, parameters: ManifestJSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A host-executed tool result returned to Letta.
public struct LettaToolReturn: Sendable, Equatable {
    public let toolCallID: String
    public let content: String
    public let isError: Bool

    public init(toolCallID: String, content: String, isError: Bool) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

/// The two request shapes one Letta turn exchanges: a user prompt, or the
/// host's answer to a paused client-tool approval.
public enum LettaMessageInput: Sendable, Equatable {
    case user(String)
    case approvals([LettaToolReturn])
}

/// One normalized event decoded from a Letta streaming response.
public enum LettaStreamEvent: Sendable, Equatable {
    /// Incremental assistant-visible text.
    case assistantText(String)
    /// The agent's reasoning text.
    case reasoning(String)
    /// A tool call the server will execute itself.
    case toolCall(id: String, name: String, arguments: String)
    /// A request to run a client-side tool on the host.
    case approvalRequest(requestID: String?, toolCallID: String, name: String, arguments: String)
    /// A tool result the server produced.
    case toolReturn(toolCallID: String, content: String, isError: Bool)
    /// The terminal stop reason for a request.
    case stopReason(String)
}

/// The transport the Letta Ascendant backend depends on.
///
/// It is a narrow, backend-private seam, not a Gnostic contract. Production
/// uses ``URLSessionLettaTransport``; tests replace it with a fixture that
/// emulates one Letta server without a live credential.
public protocol LettaTransport: Sendable {
    func health() async throws -> LettaHealth
    func listAgents(name: String) async throws -> [LettaAgentDescriptor]
    func createAgent(_ creation: LettaAgentCreation) async throws -> LettaAgentDescriptor
    func updateAgentMetadata(agentID: String, metadata: ManifestJSONValue) async throws
    func listConversations(agentID: String) async throws -> [LettaConversationDescriptor]
    func createConversation(agentID: String, description: String?) async throws -> LettaConversationDescriptor
    func updateConversation(conversationID: String, description: String?) async throws
    func deleteConversation(conversationID: String) async throws
    func sendMessage(
        agentID: String,
        conversationID: String,
        input: LettaMessageInput,
        clientTools: [LettaClientTool]
    ) async throws -> AsyncThrowingStream<LettaStreamEvent, Error>
    func cancelConversation(agentID: String, conversationID: String) async throws
}

/// A transport failure classified for the Ascendant backend contract.
public enum LettaTransportError: Error, Sendable, Equatable, LocalizedError {
    /// The Letta server could not be reached at all.
    case unreachable(String)
    /// The server answered with an authentication or authorization failure.
    case unauthorized(String)
    /// The server or a provider returned a protocol/response failure.
    case protocolFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .unreachable(detail): detail
        case let .unauthorized(detail): detail
        case let .protocolFailure(detail): detail
        }
    }
}
