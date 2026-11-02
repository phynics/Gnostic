// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPAscendant
import GnosticACPWire
import Testing

/// Exercises the stdio transport against real pipes, as a Runtime process would use it.
@Suite("ACP process stdio transport", .serialized)
struct ACPProcessStdioTransportTests {
    /// The two pipes a Runtime's stdout and stdin make, seen from the Runtime's side.
    private struct RuntimePipes {
        let stdout = Pipe()
        let stdin = Pipe()

        func makeTransport(onFailure: @escaping @Sendable () -> Void = {}) -> ACPProcessStdioTransport {
            ACPProcessStdioTransport(
                input: stdout.fileHandleForReading,
                output: stdin.fileHandleForWriting,
                onSessionUpdate: { _, _ in },
                onFailure: onFailure
            )
        }

        func runtimeWrites(_ text: String) throws {
            try stdout.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        }
    }

    private final class Counter: @unchecked Sendable { // SAFETY: The count is only read or written while holding the lock.
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func method(of message: ACPJSONRPCMessage?) -> String? {
        guard case .notification(let notification)? = message else { return nil }
        return notification.method
    }

    @Test("messages split across reads and a final unterminated line are all delivered")
    @MainActor
    func deliversMessagesAcrossReadBoundaries() async throws {
        let pipes = RuntimePipes()
        let transport = pipes.makeTransport()
        try await transport.start()
        var iterator = transport.messages.makeAsyncIterator()

        try pipes.runtimeWrites(#"{"jsonrpc":"2.0","met"#)
        try pipes.runtimeWrites("hod\":\"first\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"second\"}\n")
        #expect(Self.method(of: await iterator.next()) == "first")
        #expect(Self.method(of: await iterator.next()) == "second")

        try pipes.runtimeWrites(#"{"jsonrpc":"2.0","method":"last"}"#)
        try pipes.stdout.fileHandleForWriting.close()
        #expect(Self.method(of: await iterator.next()) == "last")
        #expect(await iterator.next() == nil)
        await transport.close()
    }

    @Test("a Runtime that exits ends the reader and reports one failure")
    @MainActor
    func runtimeExitEndsTheReader() async throws {
        let pipes = RuntimePipes()
        let failures = Counter()
        let transport = pipes.makeTransport { failures.increment() }
        try await transport.start()

        try pipes.stdout.fileHandleForWriting.close()
        var iterator = transport.messages.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        await transport.close()
        #expect(failures.count == 1)
    }

    @Test("a Runtime that closed stdin fails the transport instead of ending the process")
    @MainActor
    func brokenStdinReportsFailure() async throws {
        let pipes = RuntimePipes()
        let failures = Counter()
        let transport = pipes.makeTransport { failures.increment() }
        try await transport.start()

        try pipes.stdin.fileHandleForReading.close()
        try await transport.send(.notification(.init(method: "ping")))
        var iterator = transport.messages.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        // Closing doesn't interrupt a blocked read, so the Runtime's end goes first.
        try? pipes.stdout.fileHandleForWriting.close()
        await transport.close()
        #expect(failures.count == 1)
    }

    @Test("messages reach the Runtime's stdin in order")
    @MainActor
    func writesAreOrdered() async throws {
        let pipes = RuntimePipes()
        let transport = pipes.makeTransport()
        try await transport.start()
        for index in 0..<50 {
            try await transport.send(.notification(.init(method: "n\(index)")))
        }
        // Read before closing: the Runtime's end closing fails the transport,
        // which drops anything still queued.
        var received = Data()
        while received.filter({ $0 == 0x0A }).count < 50 {
            received.append(pipes.stdin.fileHandleForReading.availableData)
        }
        try? pipes.stdout.fileHandleForWriting.close()
        await transport.close()
        let methods = String(decoding: received, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { try? JSONDecoder().decode(ACPJSONRPCMessage.self, from: Data($0.utf8)) }
            .compactMap { Self.method(of: $0) }
        #expect(methods == (0..<50).map { "n\($0)" })
    }
}
