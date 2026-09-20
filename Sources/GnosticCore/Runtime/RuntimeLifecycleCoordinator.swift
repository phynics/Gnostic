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

    func shutdown(cleanup: @escaping @MainActor () async -> Void) async {
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
            // The join task is intentionally detached so concurrent callers
            // share one shutdown, but its cleanup body is shielded: a
            // cancellation that reaches this task must not abandon rollback
            // half-applied.
            await withCancellationShield {
                startup?.cancel()
                guard let self else { return }
                if let startup {
                    _ = await startup.result
                }
                // Startup may finish with cancellation or another failure after
                // shutdown wins. Either outcome can leave effects acquired before
                // the failure, so shutdown always owns the cleanup transition.
                await self.rollback(close: true, cleanup: cleanup)
            }
        }
        lifetime.shutdownTask = task
        await task.value
        lifetime.shutdownTask = nil
    }

    func rollback(close: Bool, cleanup: @escaping @MainActor () async -> Void) async {
        if let cleanupTask = lifetime.cleanupTask {
            await cleanupTask.value
            return
        }
        guard lifetime.beginCleanup(close: close) else { return }
        let cleanupTask = Task { @MainActor in
            await withCancellationShield {
                await cleanup()
            }
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
