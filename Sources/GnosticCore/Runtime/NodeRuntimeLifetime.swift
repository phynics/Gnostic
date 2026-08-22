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

    struct CleanupTasks {
        let reconstructions: [Task<any AscendantBackend, Error>]
        let publishTask: Task<Void, Never>?
        let resolutionTask: Task<Void, Never>?
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
    var reconstructionTasks: [UUID: Task<any AscendantBackend, Error>] = [:]
    var turnUpdatePublishTask: Task<Void, Never>?
    var networkResolutionTask: Task<Void, Never>?

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

    func beginCleanup(close: Bool) -> CleanupTasks? {
        guard !cleanupCompleted else { return nil }
        generation &+= 1
        let tasks = CleanupTasks(
            reconstructions: Array(reconstructionTasks.values),
            publishTask: turnUpdatePublishTask,
            resolutionTask: networkResolutionTask
        )
        reconstructionTasks.removeAll()
        turnUpdatePublishTask = nil
        networkResolutionTask = nil
        state = close ? .closed : .stopped
        return tasks
    }

    func markCleanupCompleted() {
        cleanupCompleted = true
    }
}
