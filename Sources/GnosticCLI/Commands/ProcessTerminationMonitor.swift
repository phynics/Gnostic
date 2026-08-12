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
    private let waiters = ProcessTerminationWaiters()
    private let lock = NSLock()
    private let signalNumbers: [Int32]
    private var sources: [DispatchSourceSignal]
    private var isCancelled = false

    init(signalNumbers: [Int32] = [SIGINT, SIGTERM]) {
        self.signalNumbers = signalNumbers
        sources = []
        for signalNumber in signalNumbers {
            ignoreSignal(signalNumber)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [waiters] in
                waiters.requestTermination()
            }
            source.activate()
            sources.append(source)
        }
    }

    func wait() async { await waiters.wait() }

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
        waiters.finish()
        signalNumbers.forEach(restoreDefaultSignalHandler)
    }

    deinit { cancel() }
}

private final class ProcessTerminationWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var terminationRequested = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if terminationRequested || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    continuations[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            resumeWaiter(id: id)
        }
    }

    func requestTermination() {
        resumeAll(markTerminated: true)
    }

    func finish() {
        resumeAll(markTerminated: false)
    }

    private func resumeWaiter(id: UUID) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume()
    }

    private func resumeAll(markTerminated: Bool) {
        lock.lock()
        if markTerminated { terminationRequested = true }
        let activeContinuations = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        activeContinuations.forEach { $0.resume() }
    }
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
