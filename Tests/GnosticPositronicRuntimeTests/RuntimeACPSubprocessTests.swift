// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
import Testing

@Suite("Positronic Runtime ACP subprocess", .serialized)
struct RuntimeACPSubprocessTests {
    @Test("Runtime advertises the pinned ACP v2 wire tag")
    func advertisesPinnedWireTag() {
        #expect(ACPv2Protocol.versionTag == "acp-v2@39ae6a2")
    }

    @Test(
        "scripted Runtime completes a multi-turn ACP v2 lifecycle",
        .timeLimit(.minutes(1)),
        .enabled(if: ProcessInfo.processInfo.environment["GNOSTIC_PK_RUNTIME_BINARY"] != nil,
                 "GNOSTIC_PK_RUNTIME_BINARY is not set")
    )
    func completesMultiplePrompts() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_PK_RUNTIME_BINARY"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var environment = ProcessInfo.processInfo.environment
        environment["GNOSTIC_PK_SCRIPTED"] = "1"
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-pk-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        environment["GNOSTIC_PK_STATE_DIR"] = stateDirectory.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        let reader = JSONLineReader(handle: output.fileHandleForReading)
        let initialize = ACPJSONRPCRequest(
            id: .int(1),
            method: ACPv2Protocol.AgentMethod.initialize,
            params: try value(ACPInitializeRequest(info: ACPImplementation(name: "test-client", version: "1")))
        )
        try send(initialize, to: input.fileHandleForWriting)
        let initialized = try await reader.read(ACPJSONRPCResponse.self)
        #expect(initialized.id == .int(1))
        #expect(initialized.error == nil)
        let initializeResult = try #require(initialized.result)
        let initializeResponse = try decode(ACPInitializeResponse.self, from: initializeResult)
        #expect(initializeResponse.protocolVersion == 2)

        let sessionNew = ACPJSONRPCRequest(
            id: .int(2),
            method: ACPv2Protocol.AgentMethod.sessionNew,
            params: try value(ACPNewSessionRequest(cwd: "/tmp"))
        )
        try send(sessionNew, to: input.fileHandleForWriting)
        let created = try await reader.read(ACPJSONRPCResponse.self)
        let newSession = try decode(ACPNewSessionResponse.self, from: #require(created.result))

        for (id, prompt) in [(3, "first"), (4, "second")] {
            let request = ACPJSONRPCRequest(
                id: .int(id),
                method: ACPv2Protocol.AgentMethod.sessionPrompt,
                params: try value(ACPPromptRequest(
                    sessionId: newSession.sessionId,
                    prompt: [.text(ACPTextContent(text: prompt))]
                ))
            )
            try send(request, to: input.fileHandleForWriting)
            let response = try await reader.response(id: id)
            #expect(response.id == .int(id))
            #expect(response.error == nil)
            let promptResponse = try decode(ACPPromptResponse.self, from: #require(response.result))

            var sawUserMessage = false
            var sawAssistantText = false
            var sawIdle = false
            while !sawIdle {
                let notification = try await reader.notification()
                #expect(notification.method == ACPv2Protocol.ClientMethod.sessionUpdate)
                let params = try decode(ACPSessionNotification.self, from: #require(notification.params))
                #expect(params.sessionId == newSession.sessionId)
                switch params.update {
                case let .userMessage(message):
                    sawUserMessage = message.messageId == promptResponse.messageId
                case let .agentMessageChunk(chunk):
                    if case let .text(text) = chunk.content {
                        sawAssistantText = sawAssistantText || text.text.contains(prompt)
                    }
                case let .stateUpdate(state):
                    if state.isIdle { sawIdle = true }
                default:
                    break
                }
            }
            #expect(sawUserMessage)
            #expect(sawAssistantText)
        }

        let close = ACPJSONRPCRequest(
            id: .int(5),
            method: ACPv2Protocol.AgentMethod.sessionClose,
            params: try value(ACPCloseSessionRequest(sessionId: newSession.sessionId))
        )
        try send(close, to: input.fileHandleForWriting)
        let closed = try await reader.read(ACPJSONRPCResponse.self)
        #expect(closed.id == .int(5))
        #expect(closed.error == nil)

        input.fileHandleForWriting.closeFile()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
    }

    private func send<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func value<T: Encodable>(_ value: T) throws -> ACPValue {
        try JSONDecoder().decode(ACPValue.self, from: JSONEncoder().encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: ACPValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

private actor JSONLineReader {
    private let handle: FileHandle
    private var pending: [ACPJSONRPCMessage] = []

    init(handle: FileHandle) {
        self.handle = handle
    }

    func read<T: Decodable>(_ type: T.Type) throws -> T {
        var bytes = Data()
        while true {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
                throw JSONLineReaderError.endOfFile
            }
            if byte[0] == 0x0A { break }
            bytes.append(byte)
        }
        return try JSONDecoder().decode(type, from: bytes)
    }

    func response(id: Int) throws -> ACPJSONRPCResponse {
        while true {
            if let index = pending.firstIndex(where: { message in
                if case let .response(response) = message { return response.id == .int(id) }
                return false
            }), case let .response(response) = pending.remove(at: index) {
                return response
            }
            let message = try read(ACPJSONRPCMessage.self)
            if case let .response(response) = message, response.id == .int(id) { return response }
            pending.append(message)
        }
    }

    func notification() throws -> ACPJSONRPCNotification {
        if let index = pending.firstIndex(where: { if case .notification = $0 { return true }; return false }),
           case let .notification(notification) = pending.remove(at: index) {
            return notification
        }
        while true {
            let message = try read(ACPJSONRPCMessage.self)
            if case let .notification(notification) = message { return notification }
            pending.append(message)
        }
    }
}

private enum JSONLineReaderError: Error {
    case endOfFile
}
