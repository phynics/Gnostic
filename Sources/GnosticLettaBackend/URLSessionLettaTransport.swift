// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GnosticCore

/// The production Letta transport. It speaks the documented Letta REST API
/// over `URLSession` and decodes Server-Sent Events.
///
/// The endpoint shapes are recorded in the issue evaluation and cited to
/// `docs.letta.com`. This type owns transport concerns only; the Ascendant
/// contract and its state mapping live in ``LettaAscendantBackend``.
public struct URLSessionLettaTransport: LettaTransport {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession

    public init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func health() async throws -> LettaHealth {
        let request = try makeRequest(method: "GET", path: "v1/health/")
        let (data, response) = try await perform(request)
        try Self.validate(response)
        let decoded = try JSONDecoder().decode(HealthBody.self, from: data)
        return LettaHealth(status: decoded.status, version: decoded.version)
    }

    public func listAgents(name: String) async throws -> [LettaAgentDescriptor] {
        let request = try makeRequest(method: "GET", path: "v1/agents/", query: [.init(name: "name", value: name)])
        let (data, response) = try await perform(request)
        try Self.validate(response)
        return try JSONDecoder().decode([AgentBody].self, from: data).map(\.descriptor)
    }

    public func createAgent(_ creation: LettaAgentCreation) async throws -> LettaAgentDescriptor {
        let body = CreateAgentBody(
            name: creation.name,
            description: creation.description,
            model: creation.model,
            metadata: creation.metadata
        )
        let request = try makeRequest(method: "POST", path: "v1/agents", body: body)
        let (data, response) = try await perform(request)
        try Self.validate(response)
        return try JSONDecoder().decode(AgentBody.self, from: data).descriptor
    }

    public func updateAgentMetadata(agentID: String, metadata: ManifestJSONValue) async throws {
        let request = try makeRequest(method: "PATCH", path: "v1/agents/\(agentID)", body: UpdateAgentBody(metadata: metadata))
        let (_, response) = try await perform(request)
        try Self.validate(response)
    }

    public func listConversations(agentID: String) async throws -> [LettaConversationDescriptor] {
        let request = try makeRequest(
            method: "GET",
            path: "v1/conversations/",
            query: [.init(name: "agent_id", value: agentID)]
        )
        let (data, response) = try await perform(request)
        try Self.validate(response)
        return try JSONDecoder().decode([ConversationBody].self, from: data).map(\.descriptor)
    }

    public func createConversation(agentID: String, description: String?) async throws -> LettaConversationDescriptor {
        let request = try makeRequest(
            method: "POST",
            path: "v1/conversations/",
            query: [.init(name: "agent_id", value: agentID)],
            body: CreateConversationBody(description: description)
        )
        let (data, response) = try await perform(request)
        try Self.validate(response)
        return try JSONDecoder().decode(ConversationBody.self, from: data).descriptor
    }

    public func updateConversation(conversationID: String, description: String?) async throws {
        let request = try makeRequest(
            method: "PATCH",
            path: "v1/conversations/\(conversationID)",
            body: UpdateConversationBody(description: description)
        )
        let (_, response) = try await perform(request)
        try Self.validate(response)
    }

    public func deleteConversation(conversationID: String) async throws {
        let request = try makeRequest(method: "DELETE", path: "v1/conversations/\(conversationID)")
        let (_, response) = try await perform(request)
        try Self.validate(response)
    }

    public func cancelConversation(agentID: String, conversationID: String) async throws {
        let request = try makeRequest(
            method: "POST",
            path: "v1/conversations/\(conversationID)/cancel",
            query: [.init(name: "agent_id", value: agentID)]
        )
        let (_, response) = try await perform(request)
        try Self.validate(response)
    }

    public func sendMessage(
        agentID: String,
        conversationID: String,
        input: LettaMessageInput,
        clientTools: [LettaClientTool]
    ) async throws -> AsyncThrowingStream<LettaStreamEvent, Error> {
        let request = try makeSendRequest(agentID: agentID, conversationID: conversationID, input: input, clientTools: clientTools)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(Darwin)
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)
                    var decoder = LettaSSEDecoder()
                    for try await line in bytes.lines {
                        for event in try decoder.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    for event in try decoder.finish() {
                        continuation.yield(event)
                    }
                    #else
                    let (data, response) = try await session.data(for: request)
                    try Self.validate(response)
                    var decoder = LettaSSEDecoder()
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
                        for event in try decoder.consume(line: String(line)) {
                            continuation.yield(event)
                        }
                    }
                    for event in try decoder.finish() {
                        continuation.yield(event)
                    }
                    #endif
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.classify(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSendRequest(
        agentID: String,
        conversationID: String,
        input: LettaMessageInput,
        clientTools: [LettaClientTool]
    ) throws -> URLRequest {
        let tools = clientTools.map(ClientToolBody.init)
        switch input {
        case let .user(content):
            let body = SendMessageBody(
                messages: [UserMessageBody(role: "user", content: content)],
                clientTools: tools.isEmpty ? nil : tools
            )
            return try makeRequest(
                method: "POST",
                path: "v1/conversations/\(conversationID)/messages",
                query: [.init(name: "agent_id", value: agentID)],
                body: body
            )
        case let .approvals(returns):
            let entries = returns.map {
                ApprovalEntry(type: "tool", toolCallID: $0.toolCallID, toolReturn: $0.content, status: $0.isError ? "error" : "success")
            }
            let body = SendMessageBody(
                messages: [ApprovalMessageBody(type: "approval", approvals: entries)],
                clientTools: tools.isEmpty ? nil : tools
            )
            return try makeRequest(
                method: "POST",
                path: "v1/conversations/\(conversationID)/messages",
                query: [.init(name: "agent_id", value: agentID)],
                body: body
            )
        }
    }

    private func makeRequest(method: String, path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        try makeRequest(method: method, path: path, query: query, bodyData: nil)
    }

    private func makeRequest<Body: Encodable>(method: String, path: String, query: [URLQueryItem] = [], body: Body) throws -> URLRequest {
        try makeRequest(method: method, path: path, query: query, bodyData: JSONEncoder().encode(body))
    }

    private func makeRequest(method: String, path: String, query: [URLQueryItem], bodyData: Data?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw LettaTransportError.unreachable("Invalid Letta server URL.")
        }
        let joined = path.hasPrefix("/") ? String(path.dropFirst()) : path
        components.path = components.path.hasSuffix("/") ? components.path + joined : components.path + "/" + joined
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw LettaTransportError.unreachable("Invalid Letta server URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Self.classify(error)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw LettaTransportError.unauthorized("Letta rejected the configured credential (HTTP \(http.statusCode)).")
        default:
            throw LettaTransportError.protocolFailure("Letta returned HTTP \(http.statusCode).")
        }
    }

    private static func classify(_ error: Error) -> LettaTransportError {
        if let error = error as? LettaTransportError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut, .secureConnectionFailed:
                return .unreachable("The Letta server is unreachable: \(error.localizedDescription)")
            default:
                return .unreachable("The Letta server request failed: \(error.localizedDescription)")
            }
        }
        if error is DecodingError {
            return .protocolFailure("The Letta server returned an unexpected response shape.")
        }
        return .protocolFailure("The Letta server request failed: \(error.localizedDescription)")
    }
}

private struct HealthBody: Decodable {
    let status: String
    let version: String?
}

private struct AgentBody: Decodable {
    let id: String
    let name: String?
    let metadata: ManifestJSONValue?

    var descriptor: LettaAgentDescriptor {
        LettaAgentDescriptor(id: id, name: name ?? id, metadata: metadata)
    }
}

private struct ConversationBody: Decodable {
    let id: String
    let agentID: String?
    let description: String?
    let archived: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case agentID = "agent_id"
        case description
        case archived
    }

    var descriptor: LettaConversationDescriptor {
        LettaConversationDescriptor(id: id, agentID: agentID ?? "", description: description, isArchived: archived ?? false)
    }
}

private struct CreateAgentBody: Encodable {
    let name: String
    let description: String?
    let model: String?
    let metadata: ManifestJSONValue?
}

private struct UpdateAgentBody: Encodable {
    let metadata: ManifestJSONValue
}

private struct CreateConversationBody: Encodable {
    let description: String?
}

private struct UpdateConversationBody: Encodable {
    let description: String?
}

private struct ClientToolBody: Encodable {
    let name: String
    let description: String
    let parameters: ManifestJSONValue

    init(_ tool: LettaClientTool) {
        name = tool.name
        description = tool.description
        parameters = tool.parameters
    }
}

private struct UserMessageBody: Encodable {
    let role: String
    let content: String
}

private struct ApprovalEntry: Encodable {
    let type: String
    let toolCallID: String
    let toolReturn: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case type
        case toolCallID = "tool_call_id"
        case toolReturn = "tool_return"
        case status
    }
}

private struct ApprovalMessageBody: Encodable {
    let type: String
    let approvals: [ApprovalEntry]
}

private struct SendMessageBody<Message: Encodable>: Encodable {
    let messages: [Message]
    let clientTools: [ClientToolBody]?
    let streaming = true
    let streamTokens = true

    enum CodingKeys: String, CodingKey {
        case messages
        case clientTools = "client_tools"
        case streaming
        case streamTokens = "stream_tokens"
    }
}

/// Decodes Letta's Server-Sent-Events frames into normalized events.
private struct LettaSSEDecoder {
    private var pending = Data()

    mutating func consume(line: String) throws -> [LettaStreamEvent] {
        if line.isEmpty {
            return try drain()
        }
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return [] }
        pending.append(contentsOf: payload.utf8)
        pending.append(0x0A)
        return []
    }

    mutating func finish() throws -> [LettaStreamEvent] {
        try drain()
    }

    private mutating func drain() throws -> [LettaStreamEvent] {
        guard !pending.isEmpty else { return [] }
        let data = pending
        pending.removeAll(keepingCapacity: true)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message: LettaWireMessage
        do {
            message = try decoder.decode(LettaWireMessage.self, from: data)
        } catch {
            return []
        }
        return message.events
    }
}

private struct LettaWireMessage: Decodable {
    let messageType: String?
    let content: ManifestJSONValue?
    let reasoning: String?
    let toolCall: LettaWireToolCall?
    let toolReturn: ManifestJSONValue?
    let status: String?
    let stopReason: String?
    let id: String?

    var events: [LettaStreamEvent] {
        var events: [LettaStreamEvent] = []
        switch messageType {
        case "assistant_message":
            if let text = Self.string(content) { events.append(.assistantText(text)) }
        case "reasoning_message":
            if let reasoning { events.append(.reasoning(reasoning)) }
        case "tool_call_message", "tool_call":
            if let toolCall {
                events.append(.toolCall(
                    id: toolCall.toolCallID ?? "",
                    name: toolCall.name ?? "",
                    arguments: Self.string(toolCall.arguments) ?? ""
                ))
            }
        case "approval_request_message":
            if let toolCall {
                events.append(.approvalRequest(
                    requestID: id,
                    toolCallID: toolCall.toolCallID ?? "",
                    name: toolCall.name ?? "",
                    arguments: Self.string(toolCall.arguments) ?? ""
                ))
            }
        case "tool_return_message":
            if let toolCall = toolCall {
                events.append(.toolReturn(
                    toolCallID: toolCall.toolCallID ?? "",
                    content: Self.string(toolReturn) ?? "",
                    isError: status != "success"
                ))
            }
        default:
            break
        }
        if let stopReason {
            events.append(.stopReason(stopReason))
        }
        return events
    }

    private static func string(_ value: ManifestJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(text): return text
        case let .number(number): return number == number.rounded() ? String(Int(number)) : String(number)
        case let .bool(flag): return flag ? "true" : "false"
        case .object, .array:
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        case .null: return nil
        }
    }
}

private struct LettaWireToolCall: Decodable {
    let name: String?
    let arguments: ManifestJSONValue?
    let toolCallID: String?
}
