// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@MainActor
final class NodeRuntimeLifetime {
    enum State: Sendable {
        case stopped
        case starting
        case running
        case closed
    }

    struct ShutdownState {
        let startupTask: Task<Void, Error>?
    }

    private(set) var state: State = .stopped
    private(set) var generation: UInt64 = 0
    private(set) var cleanupCompleted = false
    var startupTask: Task<Void, Error>?
    var shutdownTask: Task<Void, Never>?
    var cleanupTask: Task<Void, Never>?

    var isRunning: Bool { state == .running }

    @discardableResult
    func beginStart() throws -> Bool {
        switch state {
        case .running:
            return false
        case .starting:
            throw NodeRuntimeError.startInProgress
        case .closed:
            throw NodeRuntimeError.notRunning
        case .stopped:
            generation &+= 1
            cleanupCompleted = false
            state = .starting
            return true
        }
    }

    func markRunning() {
        guard state == .starting else { return }
        state = .running
    }

    func beginShutdown() -> ShutdownState? {
        guard state != .closed else { return nil }
        generation &+= 1
        state = .closed
        let startup = startupTask
        startupTask = nil
        return ShutdownState(startupTask: startup)
    }

    @discardableResult
    func beginCleanup(close: Bool) -> Bool {
        guard !cleanupCompleted else { return false }
        generation &+= 1
        state = close ? .closed : .stopped
        return true
    }

    func markCleanupCompleted() {
        cleanupCompleted = true
    }
}
