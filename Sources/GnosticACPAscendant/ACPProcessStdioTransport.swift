// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ACP
import Foundation

/// Nonblocking ACP transport for a child process's stdin and stdout pipes.
///
/// `aptove/swift-sdk` 0.1.16's `StdioTransport.start()` waits for its read and
/// write loops to finish. That blocks protocol initialization. This adapter
/// starts both loops as tasks and returns once the transport is ready for
/// protocol traffic. Re-evaluate this adapter when the SDK no longer blocks in
/// `start()`.
// SAFETY: Transport state is lock-guarded. One reader and one writer own their
// respective FileHandle operations; teardown closes both handles and awaits both tasks.
final class ACPProcessStdioTransport: Transport, @unchecked Sendable {
    let state: AsyncStream<TransportState>
    let messages: AsyncStream<JsonRpcMessage>

    private let stateContinuation: AsyncStream<TransportState>.Continuation
    private let messageContinuation: AsyncStream<JsonRpcMessage>.Continuation
    private let sendStream: AsyncStream<JsonRpcMessage>
    private let sendContinuation: AsyncStream<JsonRpcMessage>.Continuation
    private let input: FileHandle
    private let output: FileHandle
    private let onSessionUpdate: @Sendable (SessionUpdate) -> Void
    private let onFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var tornDown = false
    private var failureReported = false
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?

    init(
        input: FileHandle,
        output: FileHandle,
        onSessionUpdate: @escaping @Sendable (SessionUpdate) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.input = input
        self.output = output
        self.onSessionUpdate = onSessionUpdate
        self.onFailure = onFailure
        (state, stateContinuation) = AsyncStream.makeStream()
        (messages, messageContinuation) = AsyncStream.makeStream()
        (sendStream, sendContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.created)
    }

    func start() async throws {
        let mayStart = withLock {
            guard !started, !closed else { return false }
            started = true
            return true
        }
        guard mayStart else { throw ProtocolError.transportClosed }
        stateContinuation.yield(.starting)
        reader = Task.detached { [weak self, input, messageContinuation, stateContinuation, onSessionUpdate] in
            defer {
                messageContinuation.finish()
                if self?.isClosed == false { stateContinuation.yield(.closing) }
            }
            do {
                while !Task.isCancelled {
                    guard let line = try input.readLine() else {
                        self?.fail()
                        return
                    }
                    guard let data = line.data(using: .utf8) else { continue }
                    guard let message = try? JSONDecoder().decode(JsonRpcMessage.self, from: data) else { continue }
                    if case .notification(let notification) = message,
                       notification.method == "session/update",
                       let params = notification.params,
                       let paramsData = try? JSONEncoder().encode(params),
                       let sessionNotification = try? JSONDecoder().decode(SessionNotification.self, from: paramsData) {
                        onSessionUpdate(sessionNotification.update)
                    }
                    messageContinuation.yield(message)
                }
            } catch {
                self?.fail()
                return
            }
        }
        writer = Task.detached { [weak self, output, sendStream] in
            do {
                for await message in sendStream {
                    let data = try JSONEncoder().encode(message)
                    try output.write(contentsOf: data + Data([0x0A]))
                }
            } catch {
                self?.fail()
                return
            }
        }
        stateContinuation.yield(.started)
    }

    func send(_ message: JsonRpcMessage) async throws {
        let canSend = withLock { started && !closed }
        guard canSend else { throw ProtocolError.transportClosed }
        sendContinuation.yield(message)
    }

    func close() async {
        let shouldClose = withLock {
            guard !tornDown else { return false }
            tornDown = true
            closed = true
            return true
        }
        guard shouldClose else { return }
        sendContinuation.finish()
        reader?.cancel()
        writer?.cancel()
        try? input.close()
        try? output.close()
        if let reader { await reader.value }
        if let writer { await writer.value }
        messageContinuation.finish()
        stateContinuation.yield(.closed)
        stateContinuation.finish()
    }

    private var isClosed: Bool {
        withLock { closed }
    }

    private func fail() {
        let report = withLock {
            guard !closed else { return false }
            closed = true
            guard !failureReported else { return false }
            failureReported = true
            return true
        }
        guard report else { return }
        sendContinuation.finish()
        reader?.cancel()
        writer?.cancel()
        try? input.close()
        try? output.close()
        messageContinuation.finish()
        stateContinuation.yield(.closing)
        onFailure()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private extension FileHandle {
    func readLine() throws -> String? {
        var data = Data()
        while true {
            guard let byte = try read(upToCount: 1), !byte.isEmpty else {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if byte[0] == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
    }
}
