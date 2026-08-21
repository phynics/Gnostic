// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts
import Testing

@testable import GnosticCLI

@Suite("ACP JSON-RPC session")
struct JSONRPCSessionTests {
    @Test("initialize gates domain requests and shutdown is terminal")
    func lifecycle() async throws {
        let output = JSONRPCOutputCapture()
        let session = JSONRPCSession(handler: { request in
            if request.method == "unknown" { throw JSONRPCMethodError.methodNotFound(request.method) }
            return .string(request.method)
        }, output: output.append)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":1,"method":"session/list"}"#))
        #expect(try output.responses().last?.error?.code == JSONRPCErrorCode.invalidState.rawValue)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#))
        #expect(await session.currentState() == .initialized)
        #expect(try output.responses().last?.result != nil)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":3,"method":"unknown"}"#))
        try await waitForResponseCount(3, output: output)
        #expect(try output.responses().last?.error?.code == JSONRPCErrorCode.methodNotFound.rawValue)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":4,"method":"shutdown"}"#))
        #expect(await session.currentState() == .stopped)
        await session.receive(frame(#"{"jsonrpc":"2.0","id":5,"method":"session/list"}"#))
        #expect(try output.responses().last?.error?.code == JSONRPCErrorCode.invalidState.rawValue)
    }

    @Test("malformed frames produce parse errors and notifications stay silent")
    func malformedAndNotification() async throws {
        let output = JSONRPCOutputCapture()
        let session = JSONRPCSession(handler: { _ in .boolean(true) }, output: output.append)

        await session.receive(Data("{not json}\n".utf8))
        #expect(try output.responses().count == 1)
        #expect(try output.responses()[0].error?.code == JSONRPCErrorCode.parseError.rawValue)

        await session.receive(frame(#"{"jsonrpc":"2.0","method":"initialize"}"#))
        await session.receive(frame(#"{"jsonrpc":"2.0","method":"session/list"}"#))
        #expect(try output.responses().count == 1)
    }

    @Test("domain failures retain a stable Gnostic error code")
    func domainErrorData() async throws {
        let output = JSONRPCOutputCapture()
        let session = JSONRPCSession(handler: { _ in
            throw RemoteTurnClientError.approvalRequired
        }, output: output.append)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        await session.receive(frame(#"{"jsonrpc":"2.0","id":2,"method":"session/prompt"}"#))
        try await waitForResponseCount(2, output: output)
        let response = try #require(output.responses().last)
        #expect(response.error?.code == JSONRPCErrorCode.invalidParams.rawValue)
        #expect(response.error?.data == .dictionary(["gnosticCode": .string("approvalRequired")]))
    }

    @Test("exit stops the session")
    func exitIsTerminal() async throws {
        let output = JSONRPCOutputCapture()
        let session = JSONRPCSession(handler: { _ in .boolean(true) }, output: output.append)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":1,"method":"exit"}"#))
        #expect(await session.currentState() == .stopped)
        #expect(try output.responses().last?.result != nil)
    }

    @Test("stable request cancellation returns the ACP cancelled error")
    func stableRequestCancellation() async throws {
        let output = JSONRPCOutputCapture()
        let session = JSONRPCSession(handler: { _ in
            try await Task.sleep(for: .seconds(10))
            return .boolean(true)
        }, output: output.append)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        await session.receive(frame(#"{"jsonrpc":"2.0","id":2,"method":"long.running"}"#))
        await session.receive(frame(#"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"id":2}}"#))
        try await waitForResponseCount(2, output: output)
        let response = try #require(output.responses().last)
        #expect(response.id == .number(2))
        #expect(response.error?.code == -32800)
    }

    @Test("cancel rejects a floating identifier at the signed integer upper boundary")
    func cancelRejectsOutOfRangeFloatingIdentifier() async throws {
        let output = JSONRPCOutputCapture()
        let session = JSONRPCSession(handler: { _ in .boolean(true) }, output: output.append)

        await session.receive(frame(#"{"jsonrpc":"2.0","id":1,"method":"$/cancel_request","params":{"id":9.223372036854776e18}}"#))

        let response = try #require(output.responses().last)
        #expect(response.id == .number(1))
        #expect(response.error?.code == JSONRPCErrorCode.invalidParams.rawValue)
    }
}

private func waitForResponseCount(_ expected: Int, output: JSONRPCOutputCapture) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(1)
    while clock.now < deadline {
        if try output.responses().count >= expected { return }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(expected) JSON-RPC responses")
}

private func frame(_ json: String) -> Data {
    Data((json + "\n").utf8)
}

private final class JSONRPCOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
    }

    func responses() throws -> [JSONRPCResponse] {
        lock.lock(); defer { lock.unlock() }
        return try data.split(separator: 0x0A).map { line in
            try JSONDecoder().decode(JSONRPCResponse.self, from: Data(line))
        }
    }
}
