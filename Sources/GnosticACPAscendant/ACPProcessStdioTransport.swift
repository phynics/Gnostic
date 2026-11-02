// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
import GnosticCore
import GnosticProtocol

/// Nonblocking ACP transport for a child process's stdin and stdout pipes.
final class ACPProcessStdioTransport: ACPTransport, @unchecked Sendable { // SAFETY: Transport state is lock-guarded, and teardown closes the single-reader/single-writer FileHandles before awaiting both tasks.
    let messages: AsyncStream<ACPJSONRPCMessage>

    private let messageContinuation: AsyncStream<ACPJSONRPCMessage>.Continuation
    private let sendStream: AsyncStream<ACPJSONRPCMessage>
    private let sendContinuation: AsyncStream<ACPJSONRPCMessage>.Continuation
    private let input: FileHandle
    private let output: FileHandle
    private let onSessionUpdate: @Sendable (String, ReceivedACPUpdate) async throws -> Void
    private let onFailure: @Sendable () -> Void
    private let onDiagnostic: @Sendable (String) -> Void
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var tornDown = false
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?

    init(
        input: FileHandle,
        output: FileHandle,
        onSessionUpdate: @escaping @Sendable (String, ReceivedACPUpdate) async throws -> Void,
        onFailure: @escaping @Sendable () -> Void,
        onDiagnostic: @escaping @Sendable (String) -> Void = { ServeLogging.warn($0, component: "acp.transport") }
    ) {
        self.input = input
        self.output = output
        self.onSessionUpdate = onSessionUpdate
        self.onFailure = onFailure
        self.onDiagnostic = onDiagnostic
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
            ) { [weak self, input, messageContinuation, onSessionUpdate, onDiagnostic] in
                defer {
                    messageContinuation.finish()
                }
                do {
                    while !Task.isCancelled {
                        guard let line = try input.readLine() else {
                            self?.fail()
                            return
                        }
                        // The text is a Runtime's. Bound its nesting before anything recursive decodes it.
                        let bytes = Data(line.utf8)
                        guard !JSONNesting.exceedsMaximumDecodedDepth(bytes) else {
                            onDiagnostic("Ignored a message nested deeper than \(JSONNesting.maximumDecodedDepth) levels.")
                            continue
                        }
                        // A byte order mark stays in the frame text, but the decoder does not need it.
                        let decodable = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(bytes.dropFirst(3)) : bytes
                        guard let message = try? JSONDecoder().decode(ACPJSONRPCMessage.self, from: decodable) else { continue }
                        if case .notification(let notification) = message,
                           notification.method == ACPv2Protocol.ClientMethod.sessionUpdate {
                            // The journal keeps the text of the line. A frame with a usable
                            // sessionId is journaled even when its update does not decode.
                            if let sessionID = Self.sessionID(in: notification.params) {
                                try await onSessionUpdate(sessionID, ReceivedACPUpdate(frame: line))
                            } else {
                                onDiagnostic("Ignored a session/update without a usable sessionId; it cannot belong to a Timeline.")
                            }
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

    /// The notification's `sessionId`, when it is a non-empty string.
    private static func sessionID(in params: ACPValue?) -> String? {
        guard case let .object(fields)? = params,
              case let .string(sessionID)? = fields["sessionId"],
              !sessionID.isEmpty else { return nil }
        return sessionID
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
                return data.isEmpty ? nil : Self.text(of: data)
            }
            if byte[0] == 0x0A {
                return Self.text(of: data)
            }
            data.append(byte)
        }
    }

    /// The UTF-8 text of `data`, or `nil` when `data` is not valid UTF-8.
    ///
    /// `String(data:encoding:)` drops a leading byte order mark, so it only decides
    /// validity. The returned text keeps every byte, and invalid input is never repaired.
    private static func text(of data: Data) -> String? {
        guard String(data: data, encoding: .utf8) != nil else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
