// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
import PKContracts
import PKOpenAIProvider
import PositronicKit

@main
struct PositronicRuntimeMain {
    static func main() async {
        do {
            let runtime = try RuntimeModel.fromEnvironment()
            let sessions = try RuntimeSessions.fromEnvironment()
            try await ACPAgentServer(
                model: runtime.model,
                workspaceFactory: runtime.workspaceFactory,
                sessions: sessions
            ).run()
        } catch {
            FileHandle.standardError.write(Data("gnostic-pk-runtime: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private struct RuntimeModel {
    let model: PKRuntime
    let workspaceFactory: MCPWorkspaceFactory

    static func fromEnvironment() throws -> RuntimeModel {
        let workspaceFactory = MCPWorkspaceFactory()
        let persistence = PKRuntime.PersistenceConfiguration.inMemory()
        let runtimeConfiguration = PKRuntime.RuntimeConfiguration(workspaceCreator: workspaceFactory)
        let model: PKRuntime
        if ProcessInfo.processInfo.environment["GNOSTIC_PK_SCRIPTED"] == "1" {
            model = PKRuntime(configuration: .init(
                languageModel: ScriptedLLMClient(),
                persistence: persistence,
                runtime: runtimeConfiguration
            ))
        } else {
            guard let apiKey = ProcessInfo.processInfo.environment["GNOSTIC_PK_API_KEY"], !apiKey.isEmpty else {
                throw RuntimeConfigurationError.missingAPIKey
            }
            let modelName = ProcessInfo.processInfo.environment["GNOSTIC_PK_MODEL"] ?? "gpt-4o-mini"
            let endpoint = ProcessInfo.processInfo.environment["GNOSTIC_PK_ENDPOINT"]
            let provider = PKOpenAI.makeConfiguredProvider(apiKey: apiKey, model: modelName, endpoint: endpoint)
            model = PKRuntime(configuration: .init(
                provider: provider,
                persistence: persistence,
                runtime: runtimeConfiguration
            ))
        }
        return RuntimeModel(model: model, workspaceFactory: workspaceFactory)
    }
}

private struct ScriptedLLMClient: LLMStreamClient {
    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration { get async { .openAI } }

    func generationStreamWithContext(_ request: LLMGenerationRequest) async throws -> LLMStreamResult {
        let text = "scripted response: \(request.prompt.userQuery)"
        return LLMStreamResult(
            stream: stream(text: text),
            rawPrompt: request.prompt.userQuery
        )
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let query = messages.last(where: { $0.role == .user })?.content ?? ""
        if query.contains("[fixture:http-tool]") {
            if let toolOutput = messages.last(where: { $0.role == .tool })?.content {
                return stream(text: "scripted response after HTTP tool: \(toolOutput)")
            }
            return stream(toolName: "call_tool", arguments: #"{"tool":"http_echo","arguments":{"value":"hello"}}"#)
        }
        if query.contains("[fixture:gateway-tool]") {
            if let toolOutput = messages.last(where: { $0.role == .tool })?.content {
                return stream(text: "scripted response after Gnostic gateway tool: \(toolOutput)")
            }
            let toolName = ProcessInfo.processInfo.environment["GNOSTIC_PK_FIXTURE_TOOL_NAME"] ?? "fixture_echo"
            let invocation: [String: Any] = ["tool": toolName, "arguments": ["query": "fixture"]]
            guard let data = try? JSONSerialization.data(withJSONObject: invocation),
                  let arguments = String(data: data, encoding: .utf8) else {
                return stream(text: "scripted Runtime could not encode the gateway tool call")
            }
            return stream(toolName: "call_tool", arguments: arguments)
        }
        if query.contains("[fixture:tool]"), let toolOutput = messages.last(where: { $0.role == .tool })?.content {
            return stream(text: "scripted response after tool: \(toolOutput)")
        }
        if query.contains("[fixture:tool-after-resume]"), let toolOutput = messages.last(where: { $0.role == .tool })?.content {
            let restoredToolContext = messages.contains { $0.role == .system && $0.content.contains("fixture MCP output: hello") }
            let contextMarker = restoredToolContext ? " [prior MCP tool context restored]" : ""
            return stream(text: "scripted response after tool: \(toolOutput)\(contextMarker)")
        }
        if (query.contains("[fixture:tool]") || query.contains("[fixture:tool-after-resume]")),
           !messages.contains(where: { $0.role == .tool }) {
            return stream(toolName: "call_tool", arguments: #"{"tool":"fixture_echo","arguments":{"value":"hello"}}"#)
        }
        let restored = messages.contains { $0.role == .system && $0.content.contains("persist this conversation") }
        let contextMarker = restored ? " [restored prior context]" : ""
        return stream(
            text: "scripted response: \(query)\(contextMarker)",
            delayed: query.contains("[fixture:wait]")
        )
    }

    func generationCompletion(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async throws -> LLMStreamChunk {
        let query = messages.last(where: { $0.role == .user })?.content ?? ""
        return scriptedChunk(text: "scripted response: \(query)")
    }

    private func scriptedChunk(text: String) -> LLMStreamChunk {
        LLMStreamChunk(
            id: UUID().uuidString,
            model: "gnostic-scripted",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(role: .assistant, content: text),
                finishReason: "stop"
            )]
        )
    }

    private func stream(toolName: String, arguments: String) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let chunk = LLMStreamChunk(
            id: UUID().uuidString,
            model: "gnostic-scripted",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(role: .assistant, toolCalls: [LLMToolCallDelta(
                    index: 0,
                    id: UUID().uuidString,
                    function: LLMToolCallDeltaFunction(name: toolName, arguments: arguments)
                )]),
                finishReason: "tool_calls"
            )]
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(chunk)
            continuation.finish()
        }
    }

    private func stream(text: String, delayed: Bool = false) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            guard delayed else {
                continuation.yield(scriptedChunk(text: text))
                continuation.finish()
                return
            }
            let producer = Task {
                do {
                    try await Task.sleep(for: .seconds(20))
                    continuation.yield(scriptedChunk(text: text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }
}

private enum RuntimeConfigurationError: Error {
    case missingAPIKey
}

private actor RuntimeOutput {
    func write<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

private actor ACPAgentServer {
    private let model: PKRuntime
    private let workspaceFactory: MCPWorkspaceFactory
    private var sessions: RuntimeSessions
    private var isInitialized = false
    private let output = RuntimeOutput()

    init(model: PKRuntime, workspaceFactory: MCPWorkspaceFactory, sessions: RuntimeSessions) {
        self.model = model
        self.workspaceFactory = workspaceFactory
        self.sessions = sessions
    }

    nonisolated func run() async throws {
        while let line = try readLineFromStandardInput() {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let message = try JSONDecoder().decode(ACPJSONRPCMessage.self, from: data)
                switch message {
                case .request(let request):
                    let response = await self.handle(request)
                    try await self.output.write(response)
                case .notification(let notification):
                    await self.handle(notification)
                case .response:
                    continue
                }
            } catch {
                try await self.output.write(ACPJSONRPCResponse(
                    id: .null,
                    error: ACPJSONRPCError(
                        code: ACPv2Protocol.ErrorCode.parseError,
                        message: "Invalid JSON-RPC message"
                    )
                ))
            }
        }
        await self.shutdownActiveSessions()
    }

    private func shutdownActiveSessions() async {
        let activeSessions = sessions.activeSessions
        for session in activeSessions {
            await session.cancelAndWait()
            await detachMCPWorkspaces(session.workspaceIDs, timelineID: session.timelineID)
        }
        sessions.deactivateAll()
    }

    private func handle(_ request: ACPJSONRPCRequest) async -> ACPJSONRPCResponse {
        do {
            let result: ACPValue
            switch request.method {
            case ACPv2Protocol.AgentMethod.initialize:
                let input = try decode(ACPInitializeRequest.self, from: request.params)
                try ACPv2Protocol.validateProtocolVersion(input.protocolVersion)
                isInitialized = true
                result = try encode(ACPInitializeResponse(
                    info: ACPImplementation(
                        name: "gnostic-pk-runtime",
                        title: "Gnostic PositronicKit Runtime",
                        version: "0.5.0"
                    ),
                    capabilities: ACPAgentCapabilities(session: ACPAgentSessionCapabilities(
                        mcp: ACPMcpCapabilities(
                            stdio: ACPPresenceCapability(),
                            http: ACPPresenceCapability()
                        )
                    ))
                ))
            case ACPv2Protocol.AgentMethod.sessionNew:
                try requireInitialized()
                let input = try decode(ACPNewSessionRequest.self, from: request.params)
                let timeline = try await model.timelines.create(title: "ACP Session")
                let sessionID = UUID().uuidString.lowercased()
                let workspaceIDs = try await attachMCPServers(
                    input.mcpServers ?? [],
                    sessionID: sessionID,
                    timelineID: timeline.id
                )
                let session: RuntimeSession
                do {
                    session = try sessions.create(
                        id: sessionID,
                        cwd: input.cwd,
                        timelineID: timeline.id,
                        workspaceIDs: workspaceIDs
                    )
                } catch {
                    await detachMCPWorkspaces(workspaceIDs, timelineID: timeline.id)
                    throw error
                }
                result = try encode(ACPNewSessionResponse(sessionId: session.id))
            case ACPv2Protocol.AgentMethod.sessionPrompt:
                try requireInitialized()
                let input = try decode(ACPPromptRequest.self, from: request.params)
                guard let promptText = text(from: input.prompt) else {
                    throw ACPError.invalidParams("The Runtime accepts text prompt content only")
                }
                guard let session = sessions[sessionID: input.sessionId] else {
                    throw ACPError.invalidParams("Unknown sessionId")
                }
                let systemInstructions = try sessions.systemInstructions(sessionID: input.sessionId)
                guard await session.beginPrompt() else {
                    throw ACPError.custom(
                        code: ACPv2Protocol.ErrorCode.timelineBusy,
                        message: "Session already has an active prompt"
                    )
                }
                let userMessageID = UUID().uuidString.lowercased()
                do {
                    try await startPrompt(
                        input,
                        text: promptText,
                        systemInstructions: systemInstructions,
                        in: session,
                        userMessageID: userMessageID
                    )
                } catch {
                    await session.endPrompt()
                    throw error
                }
                result = try encode(ACPPromptResponse(messageId: userMessageID))
            case ACPv2Protocol.AgentMethod.sessionClose:
                try requireInitialized()
                let input = try decode(ACPCloseSessionRequest.self, from: request.params)
                guard let session = sessions[sessionID: input.sessionId] else {
                    throw ACPError.invalidParams("Unknown sessionId")
                }
                await session.cancelAndWait()
                guard try sessions.close(sessionID: input.sessionId) else {
                    throw ACPError.invalidParams("Unknown sessionId")
                }
                await detachMCPWorkspaces(session.workspaceIDs, timelineID: session.timelineID)
                result = try encode(ACPCloseSessionResponse())
            case ACPv2Protocol.AgentMethod.sessionResume:
                try requireInitialized()
                let input = try decode(ACPResumeSessionRequest.self, from: request.params)
                guard sessions.canResume(sessionID: input.sessionId, cwd: input.cwd) else {
                    throw ACPError.invalidParams("Session not found for the requested cwd")
                }
                if sessions[sessionID: input.sessionId] == nil {
                    let timeline = try await model.timelines.create(title: "Resumed ACP Session")
                    let workspaceIDs = try await attachMCPServers(
                        input.mcpServers ?? [],
                        sessionID: input.sessionId,
                        timelineID: timeline.id
                    )
                    do {
                        try sessions.restore(
                            sessionID: input.sessionId,
                            cwd: input.cwd,
                            timelineID: timeline.id,
                            workspaceIDs: workspaceIDs
                        )
                    } catch {
                        await detachMCPWorkspaces(workspaceIDs, timelineID: timeline.id)
                        throw error
                    }
                }
                result = try encode(ACPResumeSessionResponse())
            case ACPv2Protocol.AgentMethod.sessionList:
                try requireInitialized()
                let input = try decode(ACPListSessionsRequest.self, from: request.params)
                result = try encode(ACPListSessionsResponse(sessions: sessions.list(cwd: input.cwd)))
            default:
                throw ACPError.methodNotFound(request.method)
            }
            return ACPJSONRPCResponse(id: request.id, result: result)
        } catch let error as ACPError {
            return ACPJSONRPCResponse(id: request.id, error: error.toJSONRPCError())
        } catch {
            return ACPJSONRPCResponse(
                id: request.id,
                error: ACPJSONRPCError(
                    code: ACPv2Protocol.ErrorCode.internalError,
                    message: String(describing: error)
                )
            )
        }
    }

    private func handle(_ notification: ACPJSONRPCNotification) async {
        switch notification.method {
        case ACPv2Protocol.AgentMethod.sessionCancel:
            guard let value = notification.params,
                  let input = try? decode(ACPCancelSessionNotification.self, from: value),
                  let session = sessions[sessionID: input.sessionId] else { return }
            await session.cancel()
        case ACPv2Protocol.ProtocolMethod.cancelRequest:
            return
        default:
            return
        }
    }

    private func startPrompt(
        _ input: ACPPromptRequest,
        text prompt: String,
        systemInstructions: String,
        in session: RuntimeSession,
        userMessageID: String
    ) async throws {
        var admittedTurn: TurnHandle?
        do {
            let handle = try await model.timelines.open(session.timelineID).startDirectTurn(
                prompt,
                context: DirectTurnContext(systemInstructions: systemInstructions, contributor: .host)
            )
            admittedTurn = handle
            await session.setActiveTurn(handle)
            try sessions.appendTranscript(
                sessionID: input.sessionId,
                message: RuntimeTranscriptMessage(role: "user", content: prompt)
            )
            try await sendUpdate(sessionID: input.sessionId, update: .userMessage(ACPUserMessage(
                messageId: userMessageID,
                content: [.text(ACPTextContent(text: prompt))]
            )))
            try await sendUpdate(sessionID: input.sessionId, update: .stateUpdate(.running(meta: nil)))
            let updates = handle.events()
            Task { [weak self] in
                await self?.observe(
                    updates,
                    handle: handle,
                    sessionID: input.sessionId,
                    session: session
                )
            }
        } catch {
            if let admittedTurn {
                await admittedTurn.cancel()
                await session.clearActiveTurn()
            }
            await session.endPrompt()
            throw error
        }
    }

    private func observe(
        _ updates: AsyncStream<TurnEvent>,
        handle: TurnHandle,
        sessionID: String,
        session: RuntimeSession
    ) async {
        do {
            let assistantMessageID = UUID().uuidString.lowercased()
            var assistantText = ""
            for await event in updates {
                if case let .delta(.generation(text)) = event {
                    assistantText += text
                    try await sendUpdate(
                        sessionID: sessionID,
                        update: .agentMessageChunk(ACPContentChunk(
                            messageId: assistantMessageID,
                            content: .text(ACPTextContent(text: text))
                        ))
                    )
                }
            }
            let outcome = try await handle.outcome()
            await session.clearActiveTurn()
            let messages = try await model.timelines.messages(for: session.timelineID)
            try sessions.replaceTranscript(
                sessionID: sessionID,
                messages: messages.map(RuntimeTranscriptMessage.init)
            )
            let stopReason: ACPStopReason = switch outcome {
            case .completed: .endTurn
            case .cancelled: .cancelled
            case let .failed(message): .error(ACPJSONRPCError(
                code: ACPv2Protocol.ErrorCode.internalError,
                message: message
            ))
            case let .interrupted(reason): .error(ACPJSONRPCError(
                code: ACPv2Protocol.ErrorCode.internalError,
                message: reason
            ))
            }
            try await sendUpdate(sessionID: sessionID, update: .stateUpdate(.idle(stopReason: stopReason, meta: nil)))
            await session.endPrompt()
        } catch {
            await session.clearActiveTurn()
            try? await sendUpdate(
                sessionID: sessionID,
                update: .stateUpdate(.idle(stopReason: .error(ACPJSONRPCError(
                    code: ACPv2Protocol.ErrorCode.internalError,
                    message: String(describing: error)
                )), meta: nil))
            )
            await session.endPrompt()
            return
        }
    }

    private func sendUpdate(sessionID: String, update: ACPSessionUpdate) async throws {
        try await output.write(ACPJSONRPCNotification(
            method: ACPv2Protocol.ClientMethod.sessionUpdate,
            params: try encode(ACPSessionNotification(sessionId: sessionID, update: update))
        ))
    }

    private func attachMCPServers(
        _ servers: [ACPMcpServer],
        sessionID: String,
        timelineID: UUID
    ) async throws -> [UUID] {
        var workspaceIDs: [UUID] = []
        do {
            for server in servers {
                let name: String
                switch server {
                case let .stdio(serverName, _, _, _, _), let .http(serverName, _, _, _):
                    name = serverName
                case let .other(type, _):
                    throw ACPError.invalidParams("The Runtime does not support MCP transport '\(type)'")
                }
                let client = try MCPClientFactory.make(server: server)
                var currentWorkspaceID: UUID?
                do {
                    let definitions = try await client.initialize()
                    let workspace = try await model.workspaces.create(
                        uri: WorkspaceURI(host: "mcp-\(name)", path: "/sessions/\(sessionID)"),
                        location: .runtime
                    )
                    currentWorkspaceID = workspace.id
                    var configured = workspace
                    configured.tools = definitions.map(ToolReference.custom)
                    try await model.workspaces.update(configured)
                    try await model.timelines.attachWorkspace(configured.id, to: timelineID)
                    workspaceFactory.register(MCPWorkspaceProvider(reference: configured, client: client))
                    workspaceIDs.append(configured.id)
                    currentWorkspaceID = nil
                } catch {
                    if let currentWorkspaceID {
                        try? await model.timelines.detachWorkspace(currentWorkspaceID, from: timelineID)
                        await workspaceFactory.remove(workspaceID: currentWorkspaceID)
                        try? await model.workspaces.delete(currentWorkspaceID)
                    }
                    await client.shutdown()
                    throw error
                }
            }
            return workspaceIDs
        } catch {
            await detachMCPWorkspaces(workspaceIDs, timelineID: timelineID)
            throw error
        }
    }

    private func detachMCPWorkspaces(_ workspaceIDs: [UUID], timelineID: UUID) async {
        for workspaceID in workspaceIDs {
            try? await model.timelines.detachWorkspace(workspaceID, from: timelineID)
            await workspaceFactory.remove(workspaceID: workspaceID)
            try? await model.workspaces.delete(workspaceID)
        }
    }

    private func requireInitialized() throws {
        guard isInitialized else { throw ACPError.invalidRequest("initialize must be called first") }
    }

    private func text(from blocks: [ACPContentBlock]) -> String? {
        let text = blocks.compactMap { block -> String? in
            guard case let .text(value) = block else { return nil }
            return value.text
        }.joined()
        return text.isEmpty ? nil : text
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: ACPValue?) throws -> T {
        guard let value else { throw ACPError.invalidParams("Missing params") }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private func encode<T: Encodable>(_ value: T) throws -> ACPValue {
        try JSONDecoder().decode(ACPValue.self, from: JSONEncoder().encode(value))
    }

}

private func readLineFromStandardInput() throws -> String? {
    var bytes = Data()
    while true {
        guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else {
            return bytes.isEmpty ? nil : String(data: bytes, encoding: .utf8)
        }
        if byte[0] == 0x0A { return String(data: bytes, encoding: .utf8) }
        bytes.append(byte)
    }
}

private struct RuntimeSession: Sendable {
    let id: String
    let cwd: String
    let timelineID: UUID
    let workspaceIDs: [UUID]
    private let state = RuntimeSessionState()

    func beginPrompt() async -> Bool { await state.beginPrompt() }
    func setActiveTurn(_ turn: TurnHandle) async { await state.setActiveTurn(turn) }
    func clearActiveTurn() async { await state.setActiveTurn(nil) }
    func endPrompt() async { await state.endPrompt() }
    func cancel() async { await state.cancel() }
    func cancelAndWait() async { await state.cancelAndWait() }
}

private actor RuntimeSessionState {
    private var turn: TurnHandle?
    private var isPrompting = false
    private var cancelRequested = false
    private var promptWaiters: [CheckedContinuation<Void, Never>] = []

    func beginPrompt() -> Bool {
        guard !isPrompting else { return false }
        isPrompting = true
        cancelRequested = false
        return true
    }

    func setActiveTurn(_ turn: TurnHandle?) async {
        self.turn = turn
        if cancelRequested, let turn {
            await turn.cancel()
        }
    }
    func endPrompt() {
        isPrompting = false
        cancelRequested = false
        let waiters = promptWaiters
        promptWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func cancel() async {
        cancelRequested = true
        guard let turn else { return }
        await turn.cancel()
    }

    func cancelAndWait() async {
        cancelRequested = true
        if let turn { await turn.cancel() }
        guard isPrompting else { return }
        await withCheckedContinuation { continuation in
            if isPrompting {
                promptWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }
}

private struct RuntimeTranscriptMessage: Codable, Sendable {
    let role: String
    let content: String
    let toolCalls: String?
    let toolCallID: String?

    init(role: String, content: String, toolCalls: String? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    init(_ message: TimelineMessage) {
        role = message.role
        content = message.content
        toolCalls = message.toolCalls == "[]" ? nil : message.toolCalls
        toolCallID = message.toolCallID
    }
}

private struct PersistedRuntimeSession: Codable, Sendable, Identifiable {
    var id: String
    var cwd: String
    var title: String
    var transcript: [RuntimeTranscriptMessage]
    var updatedAt: Date
}

private struct RuntimeSessionFile: Codable {
    let formatVersion: Int
    let sessions: [PersistedRuntimeSession]
}

private struct RuntimeSessions {
    private var active: [String: RuntimeSession] = [:]
    private var persisted: [String: PersistedRuntimeSession]
    private let fileURL: URL

    static func fromEnvironment() throws -> RuntimeSessions {
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        if let configured = environment["GNOSTIC_PK_STATE_DIR"], !configured.isEmpty {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/gnostic-pk-runtime", isDirectory: true)
        }
        return try RuntimeSessions(directory: directory)
    }

    private init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fileURL = directory.appendingPathComponent("sessions.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(RuntimeSessionFile.self, from: data)
            guard file.formatVersion == 1 else {
                throw RuntimeSessionStoreError.unsupportedVersion(file.formatVersion)
            }
            persisted = Dictionary(uniqueKeysWithValues: file.sessions.map { ($0.id, $0) })
        } else {
            persisted = [:]
        }
    }

    subscript(sessionID id: String) -> RuntimeSession? { active[id] }
    var activeSessions: [RuntimeSession] { Array(active.values) }

    mutating func deactivateAll() {
        active.removeAll()
    }

    mutating func create(
        id: String,
        cwd: String,
        timelineID: UUID,
        workspaceIDs: [UUID]
    ) throws -> RuntimeSession {
        let session = RuntimeSession(id: id, cwd: cwd, timelineID: timelineID, workspaceIDs: workspaceIDs)
        let persistedSession = PersistedRuntimeSession(
            id: session.id,
            cwd: cwd,
            title: "ACP Session",
            transcript: [],
            updatedAt: Date()
        )
        active[session.id] = session
        persisted[session.id] = persistedSession
        do {
            try save()
        } catch {
            active.removeValue(forKey: session.id)
            persisted.removeValue(forKey: session.id)
            throw error
        }
        return session
    }

    func canResume(sessionID: String, cwd: String) -> Bool {
        persisted[sessionID]?.cwd == cwd
    }

    mutating func restore(sessionID: String, cwd: String, timelineID: UUID, workspaceIDs: [UUID]) throws {
        guard canResume(sessionID: sessionID, cwd: cwd) else {
            throw RuntimeSessionStoreError.unknownSession
        }
        active[sessionID] = RuntimeSession(
            id: sessionID,
            cwd: cwd,
            timelineID: timelineID,
            workspaceIDs: workspaceIDs
        )
    }

    mutating func close(sessionID: String) throws -> Bool {
        guard let removed = persisted.removeValue(forKey: sessionID) else { return false }
        let activeSession = active.removeValue(forKey: sessionID)
        do {
            try save()
        } catch {
            persisted[sessionID] = removed
            if let activeSession { active[sessionID] = activeSession }
            throw error
        }
        return true
    }

    func systemInstructions(sessionID: String) throws -> String {
        guard let transcript = persisted[sessionID]?.transcript, !transcript.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let history = String(decoding: try encoder.encode(transcript), as: UTF8.self)
        return "Continue this ACP session using its prior conversation. The transcript is JSON with role and content fields:\n\(history)"
    }

    mutating func appendTranscript(sessionID: String, message: RuntimeTranscriptMessage) throws {
        guard var session = persisted[sessionID] else { throw RuntimeSessionStoreError.unknownSession }
        session.transcript.append(message)
        session.updatedAt = Date()
        persisted[sessionID] = session
        do {
            try save()
        } catch {
            session.transcript.removeLast()
            persisted[sessionID] = session
            throw error
        }
    }

    mutating func replaceTranscript(sessionID: String, messages: [RuntimeTranscriptMessage]) throws {
        guard var session = persisted[sessionID] else { throw RuntimeSessionStoreError.unknownSession }
        let previous = session
        session.transcript = messages
        session.updatedAt = Date()
        persisted[sessionID] = session
        do {
            try save()
        } catch {
            persisted[sessionID] = previous
            throw error
        }
    }

    func list(cwd: String?) -> [ACPSessionInfo] {
        persisted.values
            .filter { cwd == nil || $0.cwd == cwd }
            .sorted { $0.id < $1.id }
            .map {
                ACPSessionInfo(
                    sessionId: $0.id,
                    cwd: $0.cwd,
                    title: $0.title,
                    updatedAt: ISO8601DateFormatter().string(from: $0.updatedAt)
                )
            }
    }

    private func save() throws {
        let file = RuntimeSessionFile(formatVersion: 1, sessions: persisted.values.sorted { $0.id < $1.id })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private enum RuntimeSessionStoreError: Error {
    case unsupportedVersion(Int)
    case unknownSession
}
