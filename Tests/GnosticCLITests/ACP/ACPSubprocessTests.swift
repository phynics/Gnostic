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
    @Test("ACP initializes and creates a Timeline session")
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
            languageModel: StubLanguageModel()
        )
        defer { serve.shutdown() }
        try await serve.start()
        await serve.advertise(
            agent: AgentInstance(
                id: agentID,
                name: "acp-smoke",
                description: "ACP fixture",
                privateTimelineID: serve.servedTimelineID
            ),
            workspaces: []
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
        let initialized = try await readResponse(from: output)
        #expect(initialized.error == nil)
        #expect(initialized.result != nil)

        try send(JSONRPCRequest(id: .number(2), method: "session/new", params: .dictionary([
            "cwd": .string("/tmp/acp-smoke"),
            "mcpServers": .array([]),
        ])))
        let created = try await readResponse(from: output)
        #expect(created.error == nil)
        let result = try #require(created.result)
        guard case let .dictionary(values) = result,
              case let .string(sessionID) = values["sessionId"] else {
            Issue.record("session/new returned no sessionId")
            return
        }
        #expect(!sessionID.isEmpty)

        try send(JSONRPCRequest(id: .number(3), method: "session/list", params: .dictionary([
            "cwd": .string("/tmp/acp-smoke")
        ])))
        let listed = try await readResponse(from: output)
        #expect(listed.error == nil)

        try send(JSONRPCRequest(id: .number(4), method: "shutdown"))
        #expect(try await readResponse(from: output).error == nil)
    }
}

private enum ACPSubprocessError: Error { case timeout }

private func readResponse(from pipe: Pipe) async throws -> JSONRPCResponse {
    let handle = pipe.fileHandleForReading
    let data = try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            try await Task.detached {
                var data = Data()
                while true {
                    let chunk = handle.readData(ofLength: 1)
                    guard !chunk.isEmpty else { throw ACPSubprocessError.timeout }
                    data.append(chunk)
                    if chunk == Data([0x0A]) { return Data(data.dropLast()) }
                }
            }.value
        }
        group.addTask {
            try await Task.sleep(for: .seconds(15))
            throw ACPSubprocessError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
    return try JSONDecoder().decode(JSONRPCResponse.self, from: data)
}
