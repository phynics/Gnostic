// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// Nonblocking ACP transport for a child process's stdin and stdout pipes.
final class ACPProcessStdioTransport: ACPTransport, @unchecked Sendable { // SAFETY: Transport state is lock-guarded, and teardown closes the single-reader/single-writer FileHandles before awaiting both tasks.
    let messages: AsyncStream<ACPJSONRPCMessage>

    private let messageContinuation: AsyncStream<ACPJSONRPCMessage>.Continuation
    private let sendStream: AsyncStream<ACPJSONRPCMessage>
    private let sendContinuation: AsyncStream<ACPJSONRPCMessage>.Continuation
    private let input: FileHandle
    private let output: FileHandle
    private let onSessionUpdate: @Sendable (String, ACPSessionUpdate) async throws -> Void
    private let onFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var tornDown = false
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?

    init(
        input: FileHandle,
        output: FileHandle,
        onSessionUpdate: @escaping @Sendable (String, ACPSessionUpdate) async throws -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.input = input
        self.output = output
        self.onSessionUpdate = onSessionUpdate
        self.onFailure = onFailure
        (messages, messageContinuation) = AsyncStream.makeStream()
        (sendStream, sendContinuation) = AsyncStream.makeStream()
    }

    func start() async throws {
        let didStart = withLock {
            guard !started, !closed else { return false }
            started = true
            BrokenPipeSignal.disable(onWriteEnd: output.fileDescriptor)
            let readerTask = Task.detached(
                executorPreference: BlockingIOTaskExecutor(label: "me.atkn.gnostic.acp.stdout")
            ) { [weak self, input, messageContinuation, onSessionUpdate] in
                defer {
                    messageContinuation.finish()
                }
                do {
                    while !Task.isCancelled {
                        guard let line = try input.readLine() else {
                            self?.fail()
                            return
                        }
                        guard let data = line.data(using: .utf8) else { continue }
                        guard let message = try? JSONDecoder().decode(ACPJSONRPCMessage.self, from: data) else { continue }
                        if case .notification(let notification) = message,
                           notification.method == ACPv2Protocol.ClientMethod.sessionUpdate,
                           let params = notification.params,
                           let paramsData = try? JSONEncoder().encode(params),
                           let sessionNotification = try? JSONDecoder().decode(ACPSessionNotification.self, from: paramsData) {
                             try await onSessionUpdate(sessionNotification.sessionId, sessionNotification.update)
                        }
                        messageContinuation.yield(message)
                    }
                } catch {
                    self?.fail()
                }
            }
            let writerTask = Task.detached(
                executorPreference: BlockingIOTaskExecutor(label: "me.atkn.gnostic.acp.stdin")
            ) { [weak self, output, sendStream] in
                do {
                    for await message in sendStream {
                        let data = try JSONEncoder().encode(message)
                        try BrokenPipeSignal.suppressed {
                            try output.write(contentsOf: data + Data([0x0A]))
                        }
                    }
                } catch {
                    self?.fail()
                }
            }
            reader = readerTask
            writer = writerTask
            return true
        }
        guard didStart else { throw ACPTransportError.transportClosed }
    }

    func send(_ message: ACPJSONRPCMessage) async throws {
        let canSend = withLock { started && !closed }
        guard canSend else { throw ACPTransportError.transportClosed }
        sendContinuation.yield(message)
    }

    func close() async {
        let snapshot = withLock {
            let ownsCleanup = !tornDown
            tornDown = true
            closed = true
            return (ownsCleanup, reader, writer, input, output)
        }
        let (ownsCleanup, reader, writer, input, output) = snapshot
        if ownsCleanup {
            sendContinuation.finish()
            reader?.cancel()
            writer?.cancel()
            try? input.close()
            try? output.close()
        }
        if let reader { await reader.value }
        if let writer { await writer.value }
        messageContinuation.finish()
    }

    private var isClosed: Bool {
        withLock { closed }
    }

    private func fail() {
        let snapshot = withLock { () -> (Task<Void, Never>?, Task<Void, Never>?, FileHandle, FileHandle)? in
            guard !closed else { return nil }
            closed = true
            tornDown = true
            return (reader, writer, input, output)
        }
        guard let (reader, writer, input, output) = snapshot else { return }
        sendContinuation.finish()
        reader?.cancel()
        writer?.cancel()
        try? input.close()
        try? output.close()
        messageContinuation.finish()
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
