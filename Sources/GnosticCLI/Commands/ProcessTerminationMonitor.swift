// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Dispatch
import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Converts process termination signals into an awaitable event without doing async work in a signal handler.
final class ProcessTerminationMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let signalNumbers: [Int32]
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var sources: [DispatchSourceSignal]
    private var isCancelled = false

    init(signalNumbers: [Int32] = [SIGINT, SIGTERM]) {
        self.signalNumbers = signalNumbers
        (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        sources = []
        for signalNumber in signalNumbers {
            ignoreSignal(signalNumber)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [continuation] in
                continuation.yield(())
            }
            source.activate()
            sources.append(source)
        }
    }

    func wait() async {
        for await _ in stream { return }
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let activeSources = sources
        sources.removeAll()
        lock.unlock()

        activeSources.forEach { $0.cancel() }
        continuation.finish()
        signalNumbers.forEach(restoreDefaultSignalHandler)
    }

    deinit { cancel() }
}

private func ignoreSignal(_ signalNumber: Int32) {
    #if os(Linux)
    _ = Glibc.signal(signalNumber, SIG_IGN)
    #else
    _ = Darwin.signal(signalNumber, SIG_IGN)
    #endif
}

private func restoreDefaultSignalHandler(_ signalNumber: Int32) {
    #if os(Linux)
    _ = Glibc.signal(signalNumber, SIG_DFL)
    #else
    _ = Darwin.signal(signalNumber, SIG_DFL)
    #endif
}
