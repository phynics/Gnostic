// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Axoloty
import GnosticCore
import PKShared
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("ACP subprocess", .serialized)
struct ACPSubprocessTests {
    @Test("pi-acp-client discovers a Gnostic profile and completes the session lifecycle", .timeLimit(.minutes(1)))
    @MainActor
    func piACPClientLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["GNOSTIC_ACP_BINARY"],
              let fixture = environment["GNOSTIC_PI_ACP_CLIENT_FIXTURE"] else { return }
        let namespace = "pi-acp-client-\(UUID().uuidString.lowercased())"
        let agentID = UUID()
        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let node = try await makeACPNode(
            namespace: namespace,
            ascendantID: agentID,
            name: "pi-acp-client",
            workspaceID: workspaceID
        )
        defer { Task { @MainActor in await node.shutdown() } }
        try await node.start()

        let sourceArguments = [
            "acp", "profiles", "--json",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/workspace/Tests/Fixtures/PiACPClient/node_modules/.bin/tsx")
        process.arguments = [fixture]
        var childEnvironment = environment
        childEnvironment["GNOSTIC_ACP_BINARY"] = binary
        childEnvironment["GNOSTIC_ACP_PROFILE_SOURCE_ARGS"] = String(
            decoding: try JSONEncoder().encode(sourceArguments),
            as: UTF8.self
        )
        let fixtureState = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-pi-acp-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureState) }
        let timelineFile = fixtureState.appendingPathComponent("timeline")
        let attachedFile = fixtureState.appendingPathComponent("attached")
        childEnvironment["GNOSTIC_STATE_HOME"] = fixtureState.appendingPathComponent("registry").path
        childEnvironment["GNOSTIC_PI_ACP_TIMELINE_FILE"] = timelineFile.path
        childEnvironment["GNOSTIC_PI_ACP_ATTACHED_FILE"] = attachedFile.path
        process.environment = childEnvironment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let attachTask = Task { @MainActor in
            let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
            defer { probe.stop() }
            try await probe.connect()
            let providerID = try await probe.selectAscendant(id: agentID).providerID
            try await poll(timeout: .seconds(30)) {
                guard FileManager.default.fileExists(atPath: timelineFile.path) else { return false }
                return try await probe.listWorkspaces(providerID: providerID).contains { $0.id == workspaceID }
            }
            let timelineText = try String(contentsOf: timelineFile, encoding: .utf8)
            let timelineID = try #require(UUID(uuidString: timelineText.trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(try await probe.attach(
                workspaceID: workspaceID,
                timelineID: timelineID,
                providerID: providerID
            ))
            try Data("ready\n".utf8).write(to: attachedFile, options: .atomic)
        }
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let attachResult = await attachTask.result
        let standardOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let standardError = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
        #expect(standardOutput.contains("pi-acp-client Gnostic lifecycle passed"))
        #expect(standardOutput.contains("pi-acp-client Workspace tool turn passed"))
        try attachResult.get()
    }

    @Test("profile discovery emits deterministic source profiles", .timeLimit(.minutes(1)))
    @MainActor
    func discoversProfiles() async throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"] else { return }
        let namespace = "acp-profiles-\(UUID().uuidString.lowercased())"
        let lowerID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let node = try await makeACPNode(
            namespace: namespace,
            ascendantID: lowerID,
            name: "Lower Ascendant"
        )
        defer { Task { @MainActor in await node.shutdown() } }
        try await node.start()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "acp", "profiles", "--json",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))

        let bundle = try JSONDecoder().decode(ACPProfileBundle.self, from: data)
        #expect(bundle.version == 1)
        #expect(bundle.profiles.map(\.id) == [
            "gnostic-10000000-0000-4000-8000-000000000001",
        ], Comment(rawValue: standardError))
        #expect(bundle.profiles.map(\.name) == ["Lower Ascendant"])
        #expect(bundle.profiles.allSatisfy { $0.command == "gnostic" && $0.env.isEmpty })
        let lowerProfile = try #require(bundle.profiles.first)
        #expect(Array(lowerProfile.args.dropLast(2)) == [
            "acp",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
            "--ascendant", lowerID.uuidString.lowercased(),
        ])
        #expect(lowerProfile.args.dropLast().last == "--provider")
        #expect(UUID(uuidString: try #require(lowerProfile.args.last)) != nil)
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(envelope.keys) == ["version", "profiles"])
    }

    @Test("official ACP client completes the stable session lifecycle", .timeLimit(.minutes(1)))
    @MainActor
    func officialClientLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GNOSTIC_ACP_BINARY"] != nil,
              let fixture = environment["GNOSTIC_ACP_OFFICIAL_CLIENT"] else { return }
        let namespace = "acp-official-\(UUID().uuidString.lowercased())"
        let agentID = UUID()
        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000002")!
        let node = try await makeACPNode(
            namespace: namespace,
            ascendantID: agentID,
            name: "official-acp-client",
            workspaceID: workspaceID
        )
        defer { Task { @MainActor in await node.shutdown() } }
        try await node.start()
        let providerID = try await discoverProviderID(namespace: namespace, ascendantID: agentID)

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-official-acp-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let arguments = [
            "acp",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
            "--ascendant", agentID.uuidString,
            "--provider", providerID,
        ]
        let argumentsData = try JSONEncoder().encode(arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/node")
        process.arguments = [fixture]
        var childEnvironment = environment
        childEnvironment["GNOSTIC_ACP_ARGS"] = String(decoding: argumentsData, as: UTF8.self)
        childEnvironment["GNOSTIC_ACP_CWD"] = "/tmp/gnostic-official-acp-client"
        childEnvironment["GNOSTIC_STATE_HOME"] = stateURL.path
        let timelineFile = stateURL.appendingPathComponent("timeline")
        let attachedFile = stateURL.appendingPathComponent("attached")
        childEnvironment["GNOSTIC_ACP_TIMELINE_FILE"] = timelineFile.path
        childEnvironment["GNOSTIC_ACP_ATTACHED_FILE"] = attachedFile.path
        process.environment = childEnvironment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let attachTask = Task { @MainActor in
            let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
            defer { probe.stop() }
            try await probe.connect()
            try await poll(timeout: .seconds(30)) {
                guard let timelineText = try? String(contentsOf: timelineFile, encoding: .utf8) else {
                    return false
                }
                return UUID(uuidString: timelineText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            }
            let timelineText = try String(contentsOf: timelineFile, encoding: .utf8)
            let timelineID = try #require(UUID(
                uuidString: timelineText.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            #expect(try await probe.attach(
                workspaceID: workspaceID,
                timelineID: timelineID,
                providerID: providerID
            ))
            try Data("ready\n".utf8).write(to: attachedFile, options: .atomic)
        }
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
        #expect(standardOutput.contains("official ACP client permission and cancellation passed"))
        try await attachTask.value
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
        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let node = try await makeACPNode(
            namespace: namespace,
            ascendantID: agentID,
            name: "acp-smoke",
            workspaceID: workspaceID
        )
        defer { Task { @MainActor in await node.shutdown() } }
        try await node.start()
        let providerID = try await discoverProviderID(namespace: namespace, ascendantID: agentID)

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
            "--provider", providerID,
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
        #expect(metadata["gnosticCWD"] == .string("/tmp/acp-smoke"))
        #expect(metadata["gnosticWorkspaceAttachmentState"] == .string("none"))
        #expect(metadata["gnosticAttachedWorkspaceIDs"] == .array([]))

        let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { probe.stop() }
        try await probe.connect()
        try await poll(timeout: .seconds(8)) {
            try await probe.listWorkspaces(providerID: providerID).contains { $0.id == workspaceID }
        }
        #expect(try await probe.attach(
            workspaceID: workspaceID,
            timelineID: timelineID,
            providerID: providerID
        ))

        try send(JSONRPCRequest(id: .number(3), method: "session/list", params: .dictionary([
            "cwd": .string("/tmp/acp-smoke")
        ])))
        let listed = try await readResponse(from: &outputIterator)
        #expect(listed.error == nil)
        guard case let .dictionary(listedResult) = listed.result,
              case let .array(listedSessions) = listedResult["sessions"],
              case let .dictionary(listedSession) = listedSessions.first else {
            Issue.record("session/list returned no session")
            return
        }
        guard case let .dictionary(listedMetadata) = listedSession["_meta"] else {
            Issue.record("session/list returned no session metadata")
            return
        }
        #expect(listedMetadata["gnosticCWD"] == .string("/tmp/acp-smoke"))
        #expect(listedMetadata["gnosticWorkspaceAttachmentState"] == .string("attached"))
        #expect(listedMetadata["gnosticAttachedWorkspaceIDs"] == .array([
            .string(workspaceID.uuidString.lowercased())
        ]))

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

        try send(JSONRPCRequest(id: nil, method: "session/cancel", params: .dictionary([
            "sessionId": .string(sessionID),
        ])))
        let cancelledPermission = JSONRPCResponse(
            id: secondPermissionRequest?.id,
            result: .dictionary([
                "outcome": .dictionary(["outcome": .string("cancelled")]),
            ])
        )
        input.fileHandleForWriting.write(try JSONEncoder().encode(cancelledPermission) + Data([0x0A]))

        let cancelledPrompt = try await readResponse(from: &outputIterator)
        #expect(cancelledPrompt.id == .number(5))
        #expect(cancelledPrompt.error == nil)
        #expect(cancelledPrompt.result == .dictionary(["stopReason": .string("cancelled")]))

        try send(JSONRPCRequest(id: .number(6), method: "session/close", params: .dictionary([
            "sessionId": .string(sessionID),
        ])))
        #expect(try await readResponse(from: &outputIterator).error == nil)

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

@MainActor
private func makeACPNode(
    namespace: String,
    ascendantID: UUID,
    name: String,
    workspaceID: UUID? = nil
) async throws -> NodeRuntime {
    let timelineID = UUID()
    let workspaces = workspaceID.map {
        [NodeManifest.Workspace(
            id: $0,
            name: "ACP echo",
            uri: "echo://acp-smoke",
            kind: "permissioned-echo"
        )]
    } ?? []
    let manifest = NodeManifest(
        broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
        node: .init(id: UUID(), approvalMode: "auto"),
        ascendants: [.init(
            id: ascendantID,
            name: name,
            defaultTimelineID: timelineID,
            description: "ACP lifecycle fixture"
        )],
        timelines: [.init(
            id: timelineID,
            title: "\(name) Timeline",
            operatingAscendantID: ascendantID
        )],
        workspaces: workspaces
    )
    var adapters = NodeRuntimeAdapters.default
    adapters.ascendants.register(kind: "positronic") { _, _ in RepeatingToolLanguageModel() }
    adapters.workspaces.register(kind: "permissioned-echo") { configuration, _ in
        let tool = WorkspaceToolDefinition(
            id: NodeRuntime.echoToolID,
            name: "Workspace echo",
            description: "Echoes fixture input.",
            requiresPermission: true
        )
        let reference = WorkspaceReference(
            id: configuration.id,
            uri: WorkspaceURI(parsing: configuration.uri)!,
            location: .runtime,
            tools: [.custom(tool)]
        )
        return PermissionedEchoWorkspace(reference: reference)
    }
    return try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
}

@MainActor
private func discoverProviderID(namespace: String, ascendantID: UUID) async throws -> String {
    let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
    defer { probe.stop() }
    try await probe.connect()
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(8)
    while clock.now < deadline {
        if let selected = try? await probe.selectAscendant(id: ascendantID) {
            return selected.providerID
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ACPSubprocessError.timeout
}

private struct PermissionedEchoWorkspace: Workspace, Sendable {
    let reference: WorkspaceReference
    var id: UUID { reference.id }

    func listTools() async throws -> [ToolReference] { reference.tools }

    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard id == NodeRuntime.echoToolID else { throw WorkspaceError.toolExecutionNotSupported }
        return .success(parameters["value"]?.value as? String ?? "")
    }

    func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    func listFiles(path _: String) async throws -> [String] { throw WorkspaceError.toolExecutionNotSupported }
    func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    func healthCheck() async -> Bool { true }
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

enum ACPSubprocessError: Error { case timeout }

enum ACPSubprocessEnvelope {
    case request(JSONRPCRequest)
    case response(JSONRPCResponse)
}

func readResponse(
    from iterator: inout AsyncStream<Data>.Iterator
) async throws -> JSONRPCResponse {
    while true {
        if case let .response(response) = try await readEnvelope(from: &iterator) { return response }
    }
}

func readEnvelope(
    from iterator: inout AsyncStream<Data>.Iterator
) async throws -> ACPSubprocessEnvelope {
    guard let data = await iterator.next() else { throw ACPSubprocessError.timeout }
    if let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) {
        return .request(request)
    }
    return .response(try JSONDecoder().decode(JSONRPCResponse.self, from: data))
}

final class LineStream: Sendable {
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

func poll(
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
