// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging

struct BackendRetirementPolicy: Sendable {
    let waitForBudget: @Sendable () async -> Void

    static let live = BackendRetirementPolicy {
        try? await Task.sleep(for: .seconds(1))
    }
}

private actor BackendRetirementLatch {
    enum Outcome: Sendable {
        case completed
        case timedOut(Set<UUID>)
    }

    private var pending: Set<UUID>
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    init(ids: Set<UUID>) {
        pending = ids
        if ids.isEmpty { outcome = .completed }
    }

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func completed(_ id: UUID) {
        guard outcome == nil else { return }
        pending.remove(id)
        guard pending.isEmpty else { return }
        resolve(.completed)
    }

    func timedOut() {
        guard outcome == nil else { return }
        resolve(.timedOut(pending))
    }

    private func resolve(_ outcome: Outcome) {
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}

@MainActor
final class BackendRetirementSupervisor {
    enum Stage: String, Sendable {
        case initializationRollback
        case reconstructionCandidate
        case quarantine
        case runtimeShutdown
    }

    private let policy: BackendRetirementPolicy
    private let logger: Logger

    init(
        policy: BackendRetirementPolicy = .live,
        logger: Logger = ServeLogging.makeLogger(label: "\(ServeLogging.subsystem).lifecycle")
    ) {
        self.policy = policy
        self.logger = logger
    }

    func retire(
        _ backends: [(id: UUID, backend: any AscendantBackend)],
        stage: Stage
    ) async {
        guard !backends.isEmpty else { return }

        let ids = Set(backends.map(\.id))
        let latch = BackendRetirementLatch(ids: ids)
        let retirementTasks = backends.map { entry in
            Task { @MainActor in
                await entry.backend.cancel()
                await entry.backend.shutdown()
                await latch.completed(entry.id)
            }
        }
        let deadlineTask = Task {
            await policy.waitForBudget()
            await latch.timedOut()
        }

        let outcome = await latch.wait()
        deadlineTask.cancel()

        guard case let .timedOut(timedOutIDs) = outcome else { return }
        retirementTasks.forEach { $0.cancel() }
        for id in timedOutIDs {
            logger.warning("backend retirement exceeded deadline", metadata: [
                "backend": .string(id.uuidString.lowercased()),
                "stage": .string(stage.rawValue),
            ])
        }
    }
}
