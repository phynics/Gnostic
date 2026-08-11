// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Axoloty
import GnosticCore
import PKShared
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("ACP subprocess")
struct ACPSubprocessTests {
    @Test("official ACP client completes the stable session lifecycle", .timeLimit(.minutes(1)))
    @MainActor
    func officialClientLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GNOSTIC_ACP_BINARY"] != nil,
              let fixture = environment["GNOSTIC_ACP_OFFICIAL_CLIENT"] else { return }
        let namespace = "acp-official-\(UUID().uuidString.lowercased())"
        let agentID = UUID()
        let serve = try await ServeRuntime(
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            approveMode: .auto,
            languageModel: RepeatingToolLanguageModel()
        )
        defer { serve.shutdown() }
        try await serve.start()
        await serve.advertise(agent: AgentInstance(
            id: agentID,
            name: "official-acp-client",
            description: "Official ACP SDK lifecycle fixture",
            privateTimelineID: serve.servedTimelineID
        ), workspaces: [])

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-official-acp-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let arguments = [
            "acp",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
            "--ascendant", agentID.uuidString,
        ]
        let argumentsData = try JSONEncoder().encode(arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/node")
        process.arguments = [fixture]
        var childEnvironment = environment
        childEnvironment["GNOSTIC_ACP_ARGS"] = String(decoding: argumentsData, as: UTF8.self)
        childEnvironment["GNOSTIC_ACP_CWD"] = "/tmp/gnostic-official-acp-client"
        childEnvironment["GNOSTIC_STATE_HOME"] = stateURL.path
        process.environment = childEnvironment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let standardOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let standardError = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
        #expect(standardOutput.contains("official ACP client lifecycle passed"))
    }

    @Test(
        "ACP initializes, creates a session, and completes a permissioned Workspace turn",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func initializesAndCreatesSession() async throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"] else { return }
        let namespace = "acp-subprocess-\(UUID().uuidString.lowercased())"
        let agentID = UUID()
        let serve = try await ServeRuntime(
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            approveMode: .auto,
            languageModel: RepeatingToolLanguageModel()
        )
        defer { serve.shutdown() }
        try await serve.start()
        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let tool = WorkspaceToolDefinition(
            id: "workspace_echo",
            name: "Workspace echo",
            description: "Echoes fixture input.",
            requiresPermission: true
        )
        let provider = WorkspaceProvider(workspaceID: workspaceID, tools: [tool]) { _, arguments in
            .success(arguments["value"]?.value as? String ?? "")
        }
        let registration = try await serve.register(workspaceProvider: provider)
        defer { registration.cancel() }
        let workspace = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://acp-smoke")!,
            location: .runtime,
            tools: [.custom(tool)],
            createdAt: Date()
        )
        await serve.advertise(
            agent: AgentInstance(
                id: agentID,
                name: "acp-smoke",
                description: "ACP fixture",
                privateTimelineID: serve.servedTimelineID
            ),
            workspaces: [workspace]
        )

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "acp",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
            "--ascendant", agentID.uuidString,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["GNOSTIC_STATE_HOME"] = stateURL.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let outputLines = LineStream(handle: output.fileHandleForReading)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        func send(_ request: JSONRPCRequest) throws {
            input.fileHandleForWriting.write(try JSONEncoder().encode(request) + Data([0x0A]))
        }

        try send(JSONRPCRequest(id: .number(1), method: "initialize", params: .dictionary([
            "protocolVersion": .number(1),
            "clientInfo": .dictionary(["name": .string("acp-smoke"), "version": .string("1")]),
        ])))
        var outputIterator = outputLines.stream.makeAsyncIterator()
        let initialized = try await readResponse(from: &outputIterator)
        #expect(initialized.error == nil)
        #expect(initialized.result != nil)

        try send(JSONRPCRequest(id: .number(2), method: "session/new", params: .dictionary([
            "cwd": .string("/tmp/acp-smoke"),
            "mcpServers": .array([]),
        ])))
        let created = try await readResponse(from: &outputIterator)
        #expect(created.error == nil)
        let result = try #require(created.result)
        guard case let .dictionary(values) = result,
              case let .string(sessionID) = values["sessionId"],
              case let .dictionary(metadata) = values["_meta"],
              case let .string(timelineRaw) = metadata["gnosticTimelineID"],
              let timelineID = UUID(uuidString: timelineRaw) else {
            Issue.record("session/new returned no sessionId")
            return
        }
        #expect(!sessionID.isEmpty)

        let client = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()
        try await poll(timeout: .seconds(8)) {
            try await client.listWorkspaces().contains { $0.id == workspaceID }
        }
        #expect(try await client.attach(workspaceID: workspaceID, timelineID: timelineID))

        try send(JSONRPCRequest(id: .number(3), method: "session/list", params: .dictionary([
            "cwd": .string("/tmp/acp-smoke")
        ])))
        let listed = try await readResponse(from: &outputIterator)
        #expect(listed.error == nil)

        try send(JSONRPCRequest(id: .number(4), method: "session/prompt", params: .dictionary([
            "sessionId": .string(sessionID),
            "prompt": .array([.dictionary(["type": .string("text"), "text": .string("use the workspace")])]),
            "mcpServers": .array([]),
            "_meta": .dictionary([ACPProtocol.turnIDMetadataKey: .string("acp-smoke:turn-1")]),
        ])))

        var permissionRequested = false
        var promptCompleted = false
        while !promptCompleted {
            switch try await readEnvelope(from: &outputIterator) {
            case .request(let request) where request.method == "session/request_permission":
                permissionRequested = true
                let response = JSONRPCResponse(id: request.id, result: .dictionary([
                    "outcome": .dictionary([
                        "outcome": .string("selected"),
                        "optionId": .string("allow_once"),
                    ]),
                ]))
                input.fileHandleForWriting.write(try JSONEncoder().encode(response) + Data([0x0A]))
            case .response(let response) where response.id == .number(4):
                #expect(response.error == nil)
                promptCompleted = true
            default:
                continue
            }
        }
        #expect(permissionRequested)

        try send(JSONRPCRequest(id: .number(5), method: "session/prompt", params: .dictionary([
            "sessionId": .string(sessionID),
            "prompt": .array([.dictionary(["type": .string("text"), "text": .string("close this turn")])]),
            "mcpServers": .array([]),
            "_meta": .dictionary([ACPProtocol.turnIDMetadataKey: .string("acp-smoke:turn-2")]),
        ])))

        var secondPermissionRequest: JSONRPCRequest?
        while secondPermissionRequest == nil {
            if case let .request(request) = try await readEnvelope(from: &outputIterator),
               request.method == "session/request_permission" {
                secondPermissionRequest = request
            }
        }

        try send(JSONRPCRequest(id: .number(6), method: "session/close", params: .dictionary([
            "sessionId": .string(sessionID),
        ])))
        var closeCompleted = false
        var cancelledPromptCompleted = false
        while !closeCompleted || !cancelledPromptCompleted {
            guard case let .response(response) = try await readEnvelope(from: &outputIterator) else { continue }
            if response.id == .number(6) {
                #expect(response.error == nil)
                closeCompleted = true
            } else if response.id == .number(5) {
                #expect(response.error != nil)
                cancelledPromptCompleted = true
            }
        }

        try send(JSONRPCRequest(id: .number(7), method: "session/resume", params: .dictionary([
            "sessionId": .string(sessionID),
            "cwd": .string("/tmp/acp-smoke"),
            "mcpServers": .array([]),
        ])))
        #expect(try await readResponse(from: &outputIterator).error == nil)

        try send(JSONRPCRequest(id: .number(8), method: "shutdown"))
        #expect(try await readResponse(from: &outputIterator).error == nil)
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let resumedProcess = Process()
        resumedProcess.executableURL = URL(fileURLWithPath: binary)
        resumedProcess.arguments = process.arguments
        resumedProcess.environment = environment
        let resumedInput = Pipe()
        let resumedOutput = Pipe()
        let resumedLines = LineStream(handle: resumedOutput.fileHandleForReading)
        resumedProcess.standardInput = resumedInput
        resumedProcess.standardOutput = resumedOutput
        resumedProcess.standardError = Pipe()
        try resumedProcess.run()
        defer { if resumedProcess.isRunning { resumedProcess.terminate() } }

        func sendAfterRestart(_ request: JSONRPCRequest) throws {
            resumedInput.fileHandleForWriting.write(try JSONEncoder().encode(request) + Data([0x0A]))
        }

        var resumedIterator = resumedLines.stream.makeAsyncIterator()
        try sendAfterRestart(JSONRPCRequest(id: .number(9), method: "initialize", params: .dictionary([
            "protocolVersion": .number(1),
            "clientInfo": .dictionary(["name": .string("acp-smoke"), "version": .string("1")]),
        ])))
        #expect(try await readResponse(from: &resumedIterator).error == nil)

        try sendAfterRestart(JSONRPCRequest(id: .number(10), method: "session/resume", params: .dictionary([
            "sessionId": .string(sessionID),
            "cwd": .string("/tmp/acp-smoke"),
            "mcpServers": .array([]),
        ])))
        #expect(try await readResponse(from: &resumedIterator).error == nil)

        try sendAfterRestart(JSONRPCRequest(id: .number(11), method: "shutdown"))
        #expect(try await readResponse(from: &resumedIterator).error == nil)
    }
}

private final class RepeatingToolLanguageModel: LanguageModel, @unchecked Sendable {
    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func chatStream(
        messages: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        if messages.last?.role == .tool {
            let chunk = LLMStreamChunk(
                id: "fixture-final",
                model: "fixture",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: "Echo received: network"),
                    finishReason: "stop"
                )]
            )
            return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
        }
        let chunk = LLMStreamChunk(
            id: "fixture-tool",
            model: "fixture",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(
                    role: .assistant,
                    toolCalls: [LLMToolCallDelta(
                        index: 0,
                        id: "call_1",
                        function: LLMToolCallDeltaFunction(
                            name: "workspace_echo",
                            arguments: #"{"value":"network"}"#
                        )
                    )]
                ),
                finishReason: "tool_calls"
            )]
        )
        return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
    }

    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}

    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { "ok" }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { "fixture" }
    func evaluateRecallPerformance(
        transcript _: String,
        recalledMemories _: [Memory]
    ) async throws -> [String: Double] { [:] }
    func fetchAvailableModels() async throws -> [String]? { nil }
}

private enum ACPSubprocessError: Error { case timeout }

private enum ACPSubprocessEnvelope {
    case request(JSONRPCRequest)
    case response(JSONRPCResponse)
}

private func readResponse(
    from iterator: inout AsyncStream<Data>.Iterator
) async throws -> JSONRPCResponse {
    while true {
        if case let .response(response) = try await readEnvelope(from: &iterator) { return response }
    }
}

private func readEnvelope(
    from iterator: inout AsyncStream<Data>.Iterator
) async throws -> ACPSubprocessEnvelope {
    guard let data = await iterator.next() else { throw ACPSubprocessError.timeout }
    if let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) {
        return .request(request)
    }
    return .response(try JSONDecoder().decode(JSONRPCResponse.self, from: data))
}

private final class LineStream: Sendable {
    let stream: AsyncStream<Data>

    init(handle: FileHandle) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.stream = stream
        Task.detached {
            var line = Data()
            while true {
                let byte = handle.readData(ofLength: 1)
                guard !byte.isEmpty else {
                    continuation.finish()
                    return
                }
                if byte == Data([0x0A]) {
                    continuation.yield(line)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        }
    }
}

private func poll(
    timeout: Duration,
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("poll condition not met before timeout")
}
