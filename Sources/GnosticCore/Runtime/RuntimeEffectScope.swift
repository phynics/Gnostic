// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The lifecycle states exposed by an effect scope.
enum RuntimeEffectScopeState: Sendable, Equatable {
    case active
    case disposing
    case disposed
}

/// Registration failures are deliberately small and contain no caller payload.
enum RuntimeEffectScopeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidName
    case invalidLabel
    case invalidAdoption
    case acquisitionClosed
    case registrationRejected(RuntimeEffectScopeState)

    var description: String {
        switch self {
        case .invalidName:
            return "The scope name must be a static diagnostic label."
        case .invalidLabel:
            return "The effect label must be a static diagnostic label."
        case .invalidAdoption:
            return "The effect scope cannot adopt itself or one of its ancestors."
        case .acquisitionClosed:
            return "The acquisition transaction is no longer accepting registrations."
        case let .registrationRejected(state):
            return "The effect scope rejected registration while it was \(state)."
        }
    }
}

/// Stable, local information about one owned effect.
struct RuntimeEffectInfo: Sendable, Equatable {
    let id: UInt64
    let label: String
    let originScope: String
    let acquisitionOrder: Int
}

/// A safe diagnostic view of one scope.
struct RuntimeEffectSnapshot: Sendable, Equatable {
    let name: String
    let state: RuntimeEffectScopeState
    let liveEffects: [RuntimeEffectInfo]
    let cleanupFailures: [RuntimeEffectCleanupFailure]
}

/// A contained cleanup failure. Underlying error values are intentionally not retained.
struct RuntimeEffectCleanupFailure: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case cleanupThrew
        case adoptedScopeFailed
    }

    let scopeName: String
    let effect: RuntimeEffectInfo
    let reason: Reason
}

/// The result of an effect or scope cleanup operation.
struct RuntimeEffectCleanupReport: Sendable, Equatable {
    let scopeName: String
    let state: RuntimeEffectScopeState
    let attemptedEffects: [RuntimeEffectInfo]
    let failures: [RuntimeEffectCleanupFailure]
    /// False only for a reentrant caller that must return while shared cleanup continues.
    let isComplete: Bool
}

/// A value acquired under a scope together with its idempotent early-disposal handle.
struct RuntimeEffectAcquisition<Value: Sendable>: Sendable {
    let value: Value
    let handle: RuntimeEffectHandle
}

/// An idempotent handle for one effect owned by a scope.
struct RuntimeEffectHandle: Sendable {
    fileprivate let scope: RuntimeEffectScope
    fileprivate let effectID: UInt64
    let info: RuntimeEffectInfo

    @discardableResult
    func dispose() async -> RuntimeEffectCleanupReport {
        await scope.disposeEffect(id: effectID)
    }
}

private struct RuntimeEffectTaskContextValue: Sendable {
    let activeScopes: Set<UUID>
    let transactionID: UUID?
    let settlement: RuntimeEffectCompletion?
}

private enum RuntimeEffectTaskContext {
    @TaskLocal static var value: RuntimeEffectTaskContextValue?
}

private actor RuntimeEffectAdoptionRegistry {
    private var children: [UUID: [UUID: Int]] = [:]

    func reserve(parent: UUID, child: UUID) -> Bool {
        guard parent != child, !reaches(from: child, target: parent) else { return false }
        children[parent, default: [:]][child, default: 0] += 1
        return true
    }

    func release(parent: UUID, child: UUID) {
        if let count = children[parent]?[child], count > 1 {
            children[parent]?[child] = count - 1
        } else {
            children[parent]?.removeValue(forKey: child)
        }
        if children[parent]?.isEmpty == true {
            children.removeValue(forKey: parent)
        }
    }

    func areRelated(_ first: UUID, _ second: Set<UUID>) -> Bool {
        second.contains(first) || second.contains { reaches(from: first, target: $0) || reaches(from: $0, target: first) }
    }

    private func reaches(from start: UUID, target: UUID) -> Bool {
        var visited: Set<UUID> = []
        var pending = [start]
        while let current = pending.popLast() {
            if !visited.insert(current).inserted { continue }
            if current == target { return true }
            if let keys = children[current]?.keys {
                pending.append(contentsOf: keys)
            }
        }
        return false
    }
}

private let runtimeEffectAdoptionRegistry = RuntimeEffectAdoptionRegistry()

private final class RuntimeEffectCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func complete() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class RuntimeEffectTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancelAndWait() async {
        let task = installedTask()
        task?.cancel()
        _ = await task?.result
    }

    private func installedTask() -> Task<Void, Never>? {
        lock.lock()
        let task = self.task
        lock.unlock()
        return task
    }
}

private final class RuntimeEffectAcquisitionCell<Value: Sendable>: @unchecked Sendable {
    private enum Outcome {
        case pending
        case acquired(Value)
        case failed
    }

    private let lock = NSLock()
    private var outcome: Outcome = .pending
    private var waiters: [CheckedContinuation<Value?, Never>] = []

    func acquired(_ value: Value) {
        finish(.acquired(value))
    }

    func failed() {
        finish(.failed)
    }

    func wait() async -> Value? {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch outcome {
            case .pending:
                waiters.append(continuation)
                lock.unlock()
            case let .acquired(value):
                lock.unlock()
                continuation.resume(returning: value)
            case .failed:
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        lock.lock()
        guard case .pending = self.outcome else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()

        for continuation in continuations {
            switch outcome {
            case let .acquired(value):
                continuation.resume(returning: value)
            case .failed:
                continuation.resume(returning: nil)
            case .pending:
                break
            }
        }
    }
}

private struct RuntimeEffectRecord: Sendable {
    let info: RuntimeEffectInfo
    let cleanup: @Sendable () async throws -> Void
    let failureReason: RuntimeEffectCleanupFailure.Reason
    let transactionID: UUID?
    let completion: RuntimeEffectCompletion
    var cleanupTask: Task<Void, Error>?
}

private struct RuntimeEffectAdoptedScopeError: Error, Sendable {}

/// Owns cooperative runtime effects and unwinds them deterministically.
actor RuntimeEffectScope {
    typealias State = RuntimeEffectScopeState
    typealias EffectInfo = RuntimeEffectInfo
    typealias Snapshot = RuntimeEffectSnapshot
    typealias CleanupFailure = RuntimeEffectCleanupFailure
    typealias CleanupReport = RuntimeEffectCleanupReport

    private let token = UUID()
    private(set) var name: String
    private(set) var state: State = .active

    private var nextEffectID: UInt64 = 0
    private var effectOrder: [UInt64] = []
    private var effects: [UInt64: RuntimeEffectRecord] = [:]
    private var activeTransactions: Set<UUID> = []
    private var pendingAcquisitions: Set<UInt64> = []
    private var deferredEffectDisposals: Set<UInt64> = []
    private var deferredEffectCleanupTasks: [UInt64: Task<Void, Never>] = [:]
    private var cleanupFailures: [RuntimeEffectCleanupFailure] = []
    private var disposalTask: Task<RuntimeEffectCleanupReport, Never>?
    private var finalReport: RuntimeEffectCleanupReport?

    init(name: StaticString) throws {
        let name = String(describing: name)
        guard Self.isSafeDiagnosticLabel(name) else {
            throw RuntimeEffectScopeError.invalidName
        }
        self.name = name
    }

    /// Adds an already-acquired cooperative resource to this scope.
    func add(
        label: StaticString,
        cleanup: @escaping @Sendable () async throws -> Void
    ) throws -> RuntimeEffectHandle {
        try register(
            label: String(describing: label),
            originScope: name,
            failureReason: .cleanupThrew,
            transactionID: currentTransactionID,
            cleanup: cleanup
        ).handle
    }

    /// Starts a cooperative task only after its ownership record has been installed.
    func task(
        label: StaticString,
        operation: @escaping @Sendable () async -> Void
    ) throws -> RuntimeEffectHandle {
        let taskBox = RuntimeEffectTaskBox()
        let registration = try register(
            label: String(describing: label),
            originScope: name,
            failureReason: .cleanupThrew,
            transactionID: currentTransactionID
        ) {
            await taskBox.cancelAndWait()
        }
        let settlement = RuntimeEffectCompletion()
        let context = RuntimeEffectTaskContextValue(
            activeScopes: currentActiveScopesIncludingSelf,
            transactionID: currentTransactionID,
            settlement: settlement
        )
        let task = Task {
            await RuntimeEffectTaskContext.$value.withValue(context) {
                await operation()
            }
            settlement.complete()
        }
        taskBox.install(task)
        return registration.handle
    }

    /// Acquires a resource with ownership reserved before acquisition can re-enter.
    func acquire<Value: Sendable>(
        label: StaticString,
        acquire: @escaping @Sendable () async throws -> Value,
        cleanup: @escaping @Sendable (Value) async throws -> Void
    ) async throws -> RuntimeEffectAcquisition<Value> {
        let cell = RuntimeEffectAcquisitionCell<Value>()
        let registration = try register(
            label: String(describing: label),
            originScope: name,
            failureReason: .cleanupThrew,
            transactionID: currentTransactionID
        ) {
            guard let value = await cell.wait() else { return }
            try await cleanup(value)
        }
        let settlement = RuntimeEffectCompletion()
        pendingAcquisitions.insert(registration.handle.effectID)
        let context = RuntimeEffectTaskContextValue(
            activeScopes: currentActiveScopesIncludingSelf,
            transactionID: currentTransactionID,
            settlement: settlement
        )

        do {
            let value = try await RuntimeEffectTaskContext.$value.withValue(context) {
                try await acquire()
            }
            cell.acquired(value)
            settlement.complete()
            pendingAcquisitions.remove(registration.handle.effectID)
            if state != .active {
                await registration.completion.wait()
            }
            return RuntimeEffectAcquisition(value: value, handle: registration.handle)
        } catch {
            cell.failed()
            settlement.complete()
            pendingAcquisitions.remove(registration.handle.effectID)
            _ = await Task.detached { await registration.handle.dispose() }.value
            throw error
        }
    }

    /// Rolls back effects registered by a failing partial-start operation.
    func withAcquisition<Value: Sendable>(
        _ operation: @escaping @Sendable (RuntimeEffectScope) async throws -> Value
    ) async throws -> Value {
        let existing = Set(effectOrder)
        let transactionID = UUID()
        activeTransactions.insert(transactionID)
        do {
            let context = RuntimeEffectTaskContextValue(
                activeScopes: currentActiveScopesIncludingSelf,
                transactionID: transactionID,
                settlement: nil
            )
            let value = try await RuntimeEffectTaskContext.$value.withValue(context) {
                try await operation(self)
            }
            if state != .active {
                _ = await disposalTask?.value
            }
            activeTransactions.remove(transactionID)
            return value
        } catch {
            let acquired = effectOrder.filter {
                !existing.contains($0) && effects[$0]?.transactionID == transactionID
            }.reversed()
            for id in acquired {
                _ = await cleanupEffect(id: id)
            }
            activeTransactions.remove(transactionID)
            throw error
        }
    }

    /// Adopts a child scope while retaining the child's own diagnostic identity.
    func adopt(_ child: RuntimeEffectScope, label: StaticString) async throws -> RuntimeEffectHandle {
        guard await runtimeEffectAdoptionRegistry.reserve(parent: token, child: await child.identityToken()) else {
            throw RuntimeEffectScopeError.invalidAdoption
        }
        do {
            let childName = await child.snapshot().name
            let registration = try register(
                label: String(describing: label),
                originScope: childName,
                failureReason: .adoptedScopeFailed,
                transactionID: currentTransactionID
            ) {
                let report = await child.dispose()
                let completedReport = report.isComplete ? report : await child.waitForDisposal()
                await runtimeEffectAdoptionRegistry.release(parent: await self.identityToken(), child: await child.identityToken())
                if !completedReport.failures.isEmpty {
                    throw RuntimeEffectAdoptedScopeError()
                }
            }
            return registration.handle
        } catch {
            await runtimeEffectAdoptionRegistry.release(parent: token, child: await child.identityToken())
            throw error
        }
    }

    /// Starts one shared reverse cleanup operation, or joins the existing one.
    func dispose() async -> RuntimeEffectCleanupReport {
        switch state {
        case .active:
            state = .disposing
            let task = Task { await self.performDisposal() }
            disposalTask = task
            if await shouldReturnBeforeDisposalCompletes() {
                return makeReport(isComplete: false)
            }
            return await task.value
        case .disposing:
            if await shouldReturnBeforeDisposalCompletes() {
                return makeReport(isComplete: false)
            }
            return await disposalTask?.value ?? makeReport(isComplete: false)
        case .disposed:
            return finalReport ?? makeReport(isComplete: true)
        }
    }

    func snapshot() -> RuntimeEffectSnapshot {
        RuntimeEffectSnapshot(
            name: name,
            state: state,
            liveEffects: effectOrder.compactMap { effects[$0]?.info },
            cleanupFailures: cleanupFailures
        )
    }

    fileprivate func disposeEffect(id: UInt64) async -> RuntimeEffectCleanupReport {
        guard let info = effects[id]?.info else {
            return finalReport ?? makeReport(attemptedEffects: [], isComplete: true)
        }
        if let context = RuntimeEffectTaskContext.value,
           await runtimeEffectAdoptionRegistry.areRelated(token, context.activeScopes) {
            if let settlement = context.settlement {
                deferEffectDisposal(id: id, after: settlement)
            }
            return makeReport(attemptedEffects: [info], isComplete: false)
        }
        _ = await cleanupEffect(id: id)
        return makeReport(attemptedEffects: [info], isComplete: true)
    }

    private func register(
        label: String,
        originScope: String,
        failureReason: RuntimeEffectCleanupFailure.Reason,
        transactionID: UUID?,
        cleanup: @escaping @Sendable () async throws -> Void
    ) throws -> (handle: RuntimeEffectHandle, completion: RuntimeEffectCompletion) {
        guard state == .active else {
            throw RuntimeEffectScopeError.registrationRejected(state)
        }
        if let transactionID, !activeTransactions.contains(transactionID) {
            throw RuntimeEffectScopeError.acquisitionClosed
        }
        guard Self.isSafeDiagnosticLabel(label) else {
            throw RuntimeEffectScopeError.invalidLabel
        }

        let id = nextEffectID
        nextEffectID &+= 1
        let info = RuntimeEffectInfo(
            id: id,
            label: label,
            originScope: originScope,
            acquisitionOrder: effectOrder.count
        )
        let completion = RuntimeEffectCompletion()
        effects[id] = RuntimeEffectRecord(
            info: info,
            cleanup: cleanup,
            failureReason: failureReason,
            transactionID: transactionID,
            completion: completion,
            cleanupTask: nil
        )
        effectOrder.append(id)
        return (RuntimeEffectHandle(scope: self, effectID: id, info: info), completion)
    }

    private func performDisposal() async -> RuntimeEffectCleanupReport {
        let ids = effectOrder.filter { effects[$0] != nil }.reversed()
        let attemptedEffects = ids.compactMap { effects[$0]?.info }
        for id in ids {
            _ = await cleanupEffect(id: id)
        }

        state = .disposed
        let report = makeReport(
            attemptedEffects: attemptedEffects,
            isComplete: true
        )
        finalReport = report
        return report
    }

    private func cleanupEffect(id: UInt64) async -> RuntimeEffectCleanupFailure? {
        guard var record = effects[id] else { return nil }
        let task: Task<Void, Error>
        if let existing = record.cleanupTask {
            task = existing
        } else {
            let cleanup = record.cleanup
            let inheritedScopes = RuntimeEffectTaskContext.value?.activeScopes ?? []
            let context = RuntimeEffectTaskContextValue(
                activeScopes: inheritedScopes.union([token]),
                transactionID: nil,
                settlement: nil
            )
            let created = Task.detached {
                try await RuntimeEffectTaskContext.$value.withValue(context) {
                    try await cleanup()
                }
            }
            record.cleanupTask = created
            effects[id] = record
            task = created
        }

        let result = await task.result
        let failure: RuntimeEffectCleanupFailure?
        switch result {
        case .success:
            failure = nil
        case .failure:
            failure = RuntimeEffectCleanupFailure(
                scopeName: name,
                effect: record.info,
                reason: record.failureReason
            )
        }

        if effects[id] != nil {
            effects.removeValue(forKey: id)
            deferredEffectDisposals.remove(id)
            deferredEffectCleanupTasks.removeValue(forKey: id)
            if let failure {
                cleanupFailures.append(failure)
            }
            record.completion.complete()
        }
        return failure
    }

    private func makeReport(isComplete: Bool) -> RuntimeEffectCleanupReport {
        makeReport(attemptedEffects: effectOrder.compactMap { effects[$0]?.info }, isComplete: isComplete)
    }

    private func makeReport(
        attemptedEffects: [RuntimeEffectInfo],
        isComplete: Bool
    ) -> RuntimeEffectCleanupReport {
        RuntimeEffectCleanupReport(
            scopeName: name,
            state: state,
            attemptedEffects: attemptedEffects,
            failures: cleanupFailures,
            isComplete: isComplete
        )
    }

    private var currentTransactionID: UUID? {
        guard let context = RuntimeEffectTaskContext.value,
              context.activeScopes.contains(token) else { return nil }
        return context.transactionID
    }

    private func shouldReturnBeforeDisposalCompletes() async -> Bool {
        if let context = RuntimeEffectTaskContext.value,
           context.activeScopes.contains(token) {
            return true
        }
        if !pendingAcquisitions.isEmpty { return true }
        if let activeScopes = RuntimeEffectTaskContext.value?.activeScopes {
            return await runtimeEffectAdoptionRegistry.areRelated(token, activeScopes)
        }
        return false
    }

    private var currentActiveScopesIncludingSelf: Set<UUID> {
        var activeScopes = RuntimeEffectTaskContext.value?.activeScopes ?? []
        activeScopes.insert(token)
        return activeScopes
    }

    private func identityToken() -> UUID {
        token
    }

    private func waitForDisposal() async -> RuntimeEffectCleanupReport {
        if let finalReport { return finalReport }
        if let disposalTask { return await disposalTask.value }
        return await dispose()
    }

    private func deferEffectDisposal(id: UInt64, after settlement: RuntimeEffectCompletion) {
        guard deferredEffectDisposals.insert(id).inserted else { return }
        let waiter = Task.detached { [weak self] in
            await settlement.wait()
            await self?.startDeferredEffectDisposal(id: id)
        }
        deferredEffectCleanupTasks[id] = waiter
    }

    private func startDeferredEffectDisposal(id: UInt64) {
        guard deferredEffectDisposals.remove(id) != nil else { return }
        deferredEffectCleanupTasks.removeValue(forKey: id)
        guard effects[id] != nil else { return }

        let cleanupTask = Task.detached { [weak self] in
            guard let self else { return }
            _ = await self.disposeEffect(id: id)
            await self.removeDeferredEffectCleanupTask(id: id)
        }
        deferredEffectCleanupTasks[id] = cleanupTask
    }

    private func removeDeferredEffectCleanupTask(id: UInt64) {
        deferredEffectCleanupTasks.removeValue(forKey: id)
    }

    private static func isSafeDiagnosticLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }
}
