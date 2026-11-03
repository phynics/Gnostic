// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum ProcessGroupSignalability: Equatable {
    case available
    case gone
    case inaccessible
    case failed
}

final class ProcessExitWaiter: @unchecked Sendable { // SAFETY: `continuation` and `result` are only accessed while holding `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediateResult = withLock { () -> Bool? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let immediateResult {
                continuation.resume(returning: immediateResult)
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                complete(false)
            }
        }
    }

    func complete(_ result: Bool) {
        let continuation = withLock { () -> CheckedContinuation<Bool, Never>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

struct RuntimeProcessTeardownOutcome: Equatable {
    var leaderExited = true
    var groupGone = true
    var incompleteDescription: String? { nil }
}

struct RuntimeProcessTeardownBounds {
    var termGraceNanoseconds: UInt64 = 1_000_000_000
    var killGraceNanoseconds: UInt64 = 1_000_000_000
    var groupExitNanoseconds: UInt64 = 1_000_000_000
}

@MainActor
final class RuntimeProcessTeardown {
    let process: Process
    let processGroupID: pid_t?
    private(set) var leaderWasReaped = false

    init(process: Process, processGroupID: pid_t?) {
        self.process = process
        self.processGroupID = processGroupID
    }

    var isLeaderRunning: Bool {
        guard process.isRunning, !leaderWasReaped else { return false }
        var status: Int32 = 0
        let result = waitpid(process.processIdentifier, &status, WNOHANG)
        if result == process.processIdentifier || (result == -1 && errno == ECHILD) {
            leaderWasReaped = true
            return false
        }
        return true
    }

    func stop(bounds: RuntimeProcessTeardownBounds = .init()) async -> RuntimeProcessTeardownOutcome {
        await stopLegacy()
        return .init()
    }

    private func stopLegacy() async {
        guard let processGroupID, processGroupID > 1 else {
            if isLeaderRunning { process.terminate() }
            if !leaderWasReaped { process.waitUntilExit() }
            return
        }

        let leaderIsRunning = isLeaderRunning
        guard processGroupSignalability(processGroupID) == .available else {
            if leaderIsRunning,
               getpgid(process.processIdentifier) == processGroupID {
                process.terminate()
                if !leaderWasReaped { process.waitUntilExit() }
            } else if !leaderWasReaped {
                process.waitUntilExit()
            }
            return
        }

        let gracefulExit = ProcessExitWaiter()
        if leaderIsRunning {
            process.terminationHandler = { _ in gracefulExit.complete(true) }
        }
        _ = signalProcessGroup(processGroupID, SIGTERM)

        guard leaderIsRunning else {
            if !leaderWasReaped { process.waitUntilExit() }
            if await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000) { return }
            _ = signalProcessGroup(processGroupID, SIGKILL)
            _ = await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000)
            return
        }

        if await gracefulExit.wait(timeoutNanoseconds: 1_000_000_000) {
            if !leaderWasReaped { process.waitUntilExit() }
            if await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000) { return }
        }

        let forcedExit = ProcessExitWaiter()
        let leaderStillRunning = isLeaderRunning
        if leaderStillRunning {
            process.terminationHandler = { _ in forcedExit.complete(true) }
        }
        _ = signalProcessGroup(processGroupID, SIGKILL)
        if !leaderStillRunning || processGroupSignalability(processGroupID) == .gone {
            forcedExit.complete(true)
        } else {
            _ = await forcedExit.wait(timeoutNanoseconds: 1_000_000_000)
        }
        if !leaderWasReaped { process.waitUntilExit() }
        _ = await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000)
    }

    private func processGroupSignalability(_ processGroupID: pid_t) -> ProcessGroupSignalability {
        guard kill(-processGroupID, 0) != 0 else { return .available }
        switch errno {
        case ESRCH: return .gone
        case EPERM: return .inaccessible
        default: return .failed
        }
    }

    private func signalProcessGroup(_ processGroupID: pid_t, _ signal: Int32) -> Bool {
        guard processGroupSignalability(processGroupID) == .available else { return false }
        return kill(-processGroupID, signal) == 0
    }

    private func waitForProcessGroupExit(_ processGroupID: pid_t, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            switch processGroupSignalability(processGroupID) {
            case .gone:
                return true
            case .inaccessible, .failed:
                return false
            case .available:
                break
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
