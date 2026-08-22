// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@MainActor
final class RuntimeLifecycleCoordinator {
    let lifetime = NodeRuntimeLifetime()

    func start(
        prepare: @escaping @MainActor (UInt64) async -> Void = { _ in },
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        guard try lifetime.beginStart() else { return }
        let generation = lifetime.generation
        await prepare(generation)
        guard lifetime.state == .starting,
              lifetime.generation == generation,
              !Task.isCancelled else {
            throw NodeRuntimeError.notRunning
        }
        let startup = Task { @MainActor in
            try await operation()
        }
        lifetime.startupTask = startup
        do {
            try await startup.value
            lifetime.startupTask = nil
        } catch {
            lifetime.startupTask = nil
            throw error
        }
        guard lifetime.state == .running, lifetime.generation == generation else {
            throw NodeRuntimeError.notRunning
        }
    }

    func shutdown(cleanup: @escaping @MainActor (NodeRuntimeLifetime.CleanupTasks) async -> Void) async {
        if let shutdownTask = lifetime.shutdownTask {
            await shutdownTask.value
            return
        }
        guard let shutdownState = lifetime.beginShutdown() else {
            if let cleanupTask = lifetime.cleanupTask { await cleanupTask.value }
            return
        }
        let startup = shutdownState.startupTask
        let task = Task { @MainActor [weak self, startup] in
            startup?.cancel()
            guard let self else { return }
            if let startup {
                let result = await startup.result
                if case .success = result {
                    await self.rollback(close: true, cleanup: cleanup)
                }
            } else {
                await self.rollback(close: true, cleanup: cleanup)
            }
        }
        lifetime.shutdownTask = task
        await task.value
        lifetime.shutdownTask = nil
    }

    func rollback(close: Bool, cleanup: @escaping @MainActor (NodeRuntimeLifetime.CleanupTasks) async -> Void) async {
        if let cleanupTask = lifetime.cleanupTask {
            await cleanupTask.value
            return
        }
        guard let tasks = lifetime.beginCleanup(close: close) else { return }
        let cleanupTask = Task { @MainActor in
            await cleanup(tasks)
        }
        lifetime.cleanupTask = cleanupTask
        await cleanupTask.value
        lifetime.cleanupTask = nil
        lifetime.markCleanupCompleted()
    }

    func requireActiveStart() throws {
        guard lifetime.state == .starting, !Task.isCancelled else { throw CancellationError() }
    }

    func requireActiveRunningStart() throws {
        guard lifetime.state == .running, !Task.isCancelled else { throw CancellationError() }
    }
}
