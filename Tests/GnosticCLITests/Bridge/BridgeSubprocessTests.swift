// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKShared
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("JSON-RPC bridge subprocess")
struct BridgeSubprocessTests {
    @Test("real bridge binary drives a live serve and one provider")
    @MainActor
    func realBridgeRoundTrip() async throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_BRIDGE_BINARY"] else {
            // The regular unit-test target intentionally does not assume a
            // built executable. `make bridge-smoke` supplies this path.
            return
        }

        let namespace = "bridge-subprocess-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let serve = try await ServeRuntime(
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            approveMode: .auto,
            languageModel: StubLanguageModel()
        )
        defer { serve.shutdown() }
        try await serve.start()

        let tools = [
            WorkspaceToolDefinition(id: "workspace_echo", name: "Workspace echo", description: "Echoes a value."),
            WorkspaceToolDefinition(id: "slow_echo", name: "Slow echo", description: "Waits before echoing."),
            WorkspaceToolDefinition(id: "permissioned", name: "Permissioned", description: "Requires approval.", requiresPermission: true),
        ]
        let invocation = InvocationProbe()
        let provider = WorkspaceProvider(workspaceID: workspaceID, tools: tools) { toolID, arguments in
            switch toolID {
            case "workspace_echo":
                await invocation.markEchoInvoked()
                return .success(arguments["value"]?.value as? String ?? "")
            case "slow_echo":
                await invocation.markStarted()
                try await Task.sleep(for: .seconds(5))
                return .success(arguments["value"]?.value as? String ?? "")
            case "permissioned":
                return .success("approved")
            default:
                return .failure("unknown tool")
            }
        }
        let registration = try await serve.register(workspaceProvider: provider)
        defer { registration.cancel() }

        let workspace = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://bridge-smoke")!,
            location: .runtime,
            tools: tools.map(ToolReference.custom),
            createdAt: Date()
        )
        await serve.advertise(
            agent: AgentInstance(name: "bridge-smoke", description: "Bridge smoke fixture.", privateTimelineID: serve.servedTimelineID),
            workspaces: [workspace]
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "bridge",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        func send(_ request: JSONRPCRequest) throws {
            input.fileHandleForWriting.write(try JSONEncoder().encode(request) + Data([0x0A]))
        }

        try send(JSONRPCRequest(id: .number(1), method: "initialize", params: .dictionary([:])))
        let initialized = try await readResponse(from: output)
        #expect(initialized.error == nil)
        #expect(initialized.result != nil)

        try send(JSONRPCRequest(id: .number(2), method: "gnostic.timeline.list"))
        let timelines = try decodeResult([TimelineStatus].self, from: await readResponse(from: output))
        #expect(timelines.contains { $0.timelineID == serve.servedTimelineID })

        try send(JSONRPCRequest(id: .number(3), method: "gnostic.workspace.list"))
        let workspaces = try decodeResult([BridgeWorkspaceSmokeSummary].self, from: await readResponse(from: output))
        let listed = try #require(workspaces.first { $0.id == workspaceID })
        #expect(listed.tools.contains { $0.id == "workspace_echo" && $0.parametersSchema != nil })
        #expect(listed.tools.contains { $0.id == "permissioned" && $0.requiresPermission })

        let attachParams = try AnyCodable.from(WorkspaceMutationSmoke(workspaceID: workspaceID, timelineID: serve.servedTimelineID))
        try send(JSONRPCRequest(id: .number(4), method: "gnostic.workspace.attach", params: attachParams))
        let attach = try await readResponse(from: output)
        #expect(attach.error == nil)

        let invokeParams = try AnyCodable.from(WorkspaceInvokeSmoke(
            workspaceID: workspaceID,
            providerID: listed.providerID,
            timelineID: serve.servedTimelineID,
            toolID: "workspace_echo",
            arguments: ["value": .string("subprocess")],
            approved: false
        ))
        try send(JSONRPCRequest(id: .number(5), method: "gnostic.workspace.invoke", params: invokeParams))
        let invoked = try await readResponse(from: output)
        #expect(invoked.error == nil)
        let toolResult = try decodeResult(ToolResult.self, from: invoked)
        #expect(toolResult.success)
        #expect(toolResult.output == "subprocess")

        let chatParams: AnyCodable = .dictionary([
            "message": .string("hello"),
            "timelineID": .string(serve.servedTimelineID.uuidString),
        ])
        try send(JSONRPCRequest(id: .number(10), method: "gnostic.ascendant.chat", params: chatParams))
        let chat = try await readResponse(from: output)
        #expect(chat.error == nil)
        #expect(try decodeResult(String.self, from: chat) == "Echo received: network")
        #expect(await invocation.echoInvocations == 2)

        // Identified bridge turns expose the idempotent result envelope. A
        // retry must replay the first terminal result without another model
        // invocation or Timeline mutation.
        let identifiedChatParams: AnyCodable = .dictionary([
            "message": .string("identified hello"),
            "timelineID": .string(serve.servedTimelineID.uuidString),
            "clientTurnID": .string("pi:bridge:entry-1"),
        ])
        try send(JSONRPCRequest(id: .number(11), method: "gnostic.ascendant.chat", params: identifiedChatParams))
        let identified = try decodeResult(BridgeChatSmokeResult.self, from: await readResponse(from: output))
        #expect(identified.clientTurnID == "pi:bridge:entry-1")
        #expect(!identified.replayed)
        #expect(identified.text == "Echo received: network")

        try send(JSONRPCRequest(id: .number(12), method: "gnostic.ascendant.chat", params: identifiedChatParams))
        let replay = try decodeResult(BridgeChatSmokeResult.self, from: await readResponse(from: output))
        #expect(replay.clientTurnID == identified.clientTurnID)
        #expect(replay.text == identified.text)
        #expect(replay.replayed)

        let permissionParams = try AnyCodable.from(WorkspaceInvokeSmoke(
            workspaceID: workspaceID,
            providerID: listed.providerID,
            timelineID: serve.servedTimelineID,
            toolID: "permissioned",
            arguments: [:],
            approved: false
        ))
        try send(JSONRPCRequest(id: .number(6), method: "gnostic.workspace.invoke", params: permissionParams))
        #expect(try await readResponse(from: output).error != nil)

        let slowParams = try AnyCodable.from(WorkspaceInvokeSmoke(
            workspaceID: workspaceID,
            providerID: listed.providerID,
            timelineID: serve.servedTimelineID,
            toolID: "slow_echo",
            arguments: ["value": .string("cancelled")],
            approved: false
        ))
        try send(JSONRPCRequest(id: .number(7), method: "gnostic.workspace.invoke", params: slowParams))
        try await waitUntil(timeout: .seconds(10)) { await invocation.hasStarted }
        let cancelParams: AnyCodable = .dictionary(["id": .number(7)])
        try send(JSONRPCRequest(id: nil, method: "$/cancelRequest", params: cancelParams))

        try send(JSONRPCRequest(id: .number(8), method: "gnostic.timeline.status", params: .dictionary(["timelineID": .string(serve.servedTimelineID.uuidString)])))
        let afterCancellation = try await readResponse(from: output)
        #expect(afterCancellation.id == .number(8))
        #expect(afterCancellation.error == nil)
        // Axoloty Call/Return has no remote cancellation frame. The bridge
        // cancels its local wait and suppresses the id-7 response.

        try send(JSONRPCRequest(id: .number(9), method: "shutdown"))
        #expect(try await readResponse(from: output).error == nil)
        try await waitForTermination(process)
        #expect(process.terminationStatus == 0)
    }
}

private enum BridgeSmokeError: Error {
    case timeout
}

private actor InvocationProbe {
    private var started = false
    private(set) var echoInvocations = 0

    func markStarted() { started = true }
    func markEchoInvoked() { echoInvocations += 1 }
    var hasStarted: Bool { started }
}

private struct WorkspaceMutationSmoke: Codable {
    let workspaceID: UUID
    let timelineID: UUID
}

private struct WorkspaceInvokeSmoke: Codable {
    let workspaceID: UUID
    let providerID: String
    let timelineID: UUID
    let toolID: String
    let arguments: [String: AnyCodable]
    let approved: Bool
}

private struct BridgeWorkspaceSmokeSummary: Decodable {
    let id: UUID
    let providerID: String
    let tools: [BridgeToolSmokeSummary]
}

private struct BridgeChatSmokeResult: Decodable {
    let clientTurnID: String?
    let text: String
    let replayed: Bool
}

private struct BridgeToolSmokeSummary: Decodable {
    let id: String
    let parametersSchema: [String: AnyCodable]?
    let requiresPermission: Bool
}

private extension AnyCodable {
    static func from<T: Encodable>(_ value: T) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(value))
    }
}

private func decodeResult<T: Decodable>(_ type: T.Type, from response: JSONRPCResponse) throws -> T {
    guard let result = response.result else { throw BridgeSmokeError.timeout }
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(result))
}

private func readResponse(from pipe: Pipe) async throws -> JSONRPCResponse {
    let handle = pipe.fileHandleForReading
    let data = try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            try await Task.detached {
                var data = Data()
                while true {
                    let chunk = handle.readData(ofLength: 1)
                    guard !chunk.isEmpty else { throw BridgeSmokeError.timeout }
                    data.append(chunk)
                    if chunk == Data([0x0A]) { return Data(data.dropLast()) }
                }
            }.value
        }
        group.addTask {
            try await Task.sleep(for: .seconds(15))
            throw BridgeSmokeError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
    return try JSONDecoder().decode(JSONRPCResponse.self, from: data)
}

private func waitForTermination(_ process: Process) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while process.isRunning, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    guard !process.isRunning else { throw BridgeSmokeError.timeout }
}

private func waitUntil(
    timeout: Duration,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw BridgeSmokeError.timeout
}
