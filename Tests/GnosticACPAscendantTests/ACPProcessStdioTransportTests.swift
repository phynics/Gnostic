// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPAscendant
import GnosticACPWire
import GnosticCore
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

    private final class Recorder: @unchecked Sendable { // SAFETY: Both arrays are only read or written while holding the lock.
        private let lock = NSLock()
        private var updates: [(sessionID: String, received: ReceivedACPUpdate)] = []
        private var diagnostics: [String] = []

        func record(_ sessionID: String, _ received: ReceivedACPUpdate) {
            lock.lock(); defer { lock.unlock() }
            updates.append((sessionID, received))
        }

        func diagnose(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            diagnostics.append(message)
        }

        var snapshot: (updates: [(sessionID: String, received: ReceivedACPUpdate)], diagnostics: [String]) {
            lock.lock(); defer { lock.unlock() }
            return (updates, diagnostics)
        }
    }

    @Test("a session/update with a sessionId is handed over as its line, and one without is diagnosed and skipped")
    @MainActor
    func sessionUpdateFramesAreHandedOverAsText() async throws {
        let pipes = RuntimePipes()
        let recorder = Recorder()
        let failures = Counter()
        let transport = ACPProcessStdioTransport(
            input: pipes.stdout.fileHandleForReading,
            output: pipes.stdin.fileHandleForWriting,
            onSessionUpdate: { recorder.record($0, $1) },
            onFailure: { failures.increment() },
            onDiagnostic: { recorder.diagnose($0) }
        )
        try await transport.start()
        var iterator = transport.messages.makeAsyncIterator()

        let fits = #"{ "jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1","update":{"sessionUpdate":"state_update","state":"running","big":18446744073709551617}} }"#
        let misfit = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":"not-an-object"}}"#
        let noSession = #"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"vendor_orphan"}}}"#
        let emptySession = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"","update":{"sessionUpdate":"vendor_orphan"}}}"#
        let notJSONRPC = "not json at all"
        let last = #"{"jsonrpc":"2.0","method":"last"}"#
        try pipes.runtimeWrites([fits, misfit, noSession, emptySession, notJSONRPC, last].joined(separator: "\n") + "\n")

        // The transport stays usable: every JSON-RPC message still arrives.
        for _ in 0..<4 { #expect(Self.method(of: await iterator.next()) == "session/update") }
        #expect(Self.method(of: await iterator.next()) == "last")
        try pipes.stdout.fileHandleForWriting.close()
        #expect(await iterator.next() == nil)
        await transport.close()

        let seen = recorder.snapshot
        #expect(seen.updates.map(\.sessionID) == ["s1", "s1"])
        #expect(seen.updates.map(\.received.frame) == [fits, misfit])
        #expect(seen.updates[0].received.update == .stateUpdate(.running(meta: nil)))
        #expect(seen.updates[1].received.update == nil)
        #expect(seen.diagnostics.count == 2, "Each frame without a usable sessionId is diagnosed once.")
        #expect(!seen.diagnostics.contains { $0.contains("vendor_orphan") }, "A diagnostic must not carry Runtime content.")
        #expect(failures.count == 1, "Only the Runtime's exit fails the transport.")
    }

    @Test("a message nested past the bound is diagnosed and skipped, and one at the bound is handed over whole")
    @MainActor
    func deepMessagesAreBoundedBeforeDecoding() async throws {
        let pipes = RuntimePipes()
        let recorder = Recorder()
        let failures = Counter()
        let transport = ACPProcessStdioTransport(
            input: pipes.stdout.fileHandleForReading,
            output: pipes.stdin.fileHandleForWriting,
            onSessionUpdate: { recorder.record($0, $1) },
            onFailure: { failures.increment() },
            onDiagnostic: { recorder.diagnose($0) }
        )
        try await transport.start()
        var iterator = transport.messages.makeAsyncIterator()

        func frame(depth: Int) -> String {
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"state_update","state":"running","deep":"#
                + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}}}"
        }
        // The envelope, `params`, and `update` take three levels.
        let bound = JSONNesting.maximumDecodedDepth
        let atBound = frame(depth: bound - 3)
        let pastBound = frame(depth: bound - 2)
        // A response nests too, and is bounded like any other message.
        let deepResponse = #"{"jsonrpc":"2.0","id":1,"result":"#
            + String(repeating: "[", count: 507) + String(repeating: "]", count: 507) + "}"
        let last = #"{"jsonrpc":"2.0","method":"last"}"#
        try pipes.runtimeWrites([pastBound, frame(depth: 507), frame(depth: 100_000), deepResponse, atBound, last]
            .joined(separator: "\n") + "\n")

        #expect(Self.method(of: await iterator.next()) == "session/update")
        #expect(Self.method(of: await iterator.next()) == "last")
        try pipes.stdout.fileHandleForWriting.close()
        #expect(await iterator.next() == nil)
        await transport.close()

        let seen = recorder.snapshot
        #expect(seen.updates.map(\.received.frame) == [atBound])
        #expect(seen.updates.first?.received.update == .stateUpdate(.running(meta: nil)))
        #expect(seen.diagnostics.count == 4, "Each message past the bound is diagnosed once.")
        #expect(!seen.diagnostics.contains { $0.contains("state_update") || $0.contains("s1") }, "A diagnostic must not carry Runtime content.")
        #expect(failures.count == 1, "Only the Runtime's exit fails the transport.")
    }

    @Test("a frame keeps a leading byte order mark and a trailing carriage return, and invalid UTF-8 is not repaired")
    @MainActor
    func frameTextKeepsItsBytes() async throws {
        let body = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"state_update","state":"running","text":"\#u{E9}\#u{1F600}"}}}"#
        let expected = ["\u{FEFF}" + body + "\r", body + "\r", body]

        let pipes = RuntimePipes()
        let recorder = Recorder()
        let failures = Counter()
        let transport = ACPProcessStdioTransport(
            input: pipes.stdout.fileHandleForReading,
            output: pipes.stdin.fileHandleForWriting,
            onSessionUpdate: { recorder.record($0, $1) },
            onFailure: { failures.increment() },
            onDiagnostic: { recorder.diagnose($0) }
        )
        try await transport.start()
        var iterator = transport.messages.makeAsyncIterator()
        try pipes.runtimeWrites(expected.joined(separator: "\n") + "\n")
        for _ in 0..<3 { #expect(Self.method(of: await iterator.next()) == "session/update") }

        let seen = recorder.snapshot
        #expect(seen.updates.map { Array($0.received.frame?.utf8 ?? "".utf8) } == expected.map { Array($0.utf8) })
        #expect(seen.updates.allSatisfy { $0.received.update == .stateUpdate(.running(meta: nil)) })

        // Invalid UTF-8 ends the transport, as it did before. It is not turned into U+FFFD.
        try pipes.stdout.fileHandleForWriting.write(contentsOf: Data([0xFF, 0xFE, 0x0A]))
        #expect(await iterator.next() == nil)
        await transport.close()
        #expect(failures.count == 1)
        #expect(recorder.snapshot.updates.count == 3)
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
            let chunk = pipes.stdin.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            received.append(chunk)
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
