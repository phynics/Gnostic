// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Runtime effect scope")
struct RuntimeEffectScopeTests {
    @Test("effects clean up in reverse acquisition order and snapshots expose live state")
    func effectsCleanUpInReverseAcquisitionOrder() async throws {
        let scope = try RuntimeEffectScope(name: "runtime-test")
        let events = EventLog()

        _ = try await scope.add(label: "first") { await events.record("first") }
        _ = try await scope.add(label: "second") { await events.record("second") }
        _ = try await scope.add(label: "synchronous") {}
        let active = await scope.snapshot()

        #expect(active.state == .active)
        #expect(active.liveEffects.map(\.label) == ["first", "second", "synchronous"])
        #expect(active.liveEffects.map(\.acquisitionOrder) == [0, 1, 2])

        let report = await scope.dispose()

        #expect(await events.values == ["second", "first"])
        #expect(report.isComplete)
        #expect(report.failures.isEmpty)
        #expect((await scope.snapshot()).state == .disposed)
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("task disposal requests cancellation and waits for task settlement")
    func taskDisposalRequestsCancellationAndWaitsForSettlement() async throws {
        let scope = try RuntimeEffectScope(name: "task-test")
        let events = EventLog()

        _ = try await scope.task(label: "worker") {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                await events.record("cancelled")
            }
            await events.record("settled")
        }

        let report = await scope.dispose()

        #expect(await events.values == ["cancelled", "settled"])
        #expect(report.isComplete)
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("task work can request reentrant disposal after ownership is installed")
    func taskWorkCanRequestReentrantDisposalAfterOwnershipIsInstalled() async throws {
        let scope = try RuntimeEffectScope(name: "task-reentrant")
        let events = EventLog()

        _ = try await scope.task(label: "worker") {
            await events.record("started")
            let report = await scope.dispose()
            #expect(!report.isComplete)
            await events.record("settled")
        }

        await events.waitFor("settled")
        let report = await scope.dispose()
        #expect(await events.values == ["started", "settled"])
        #expect(report.isComplete)
        #expect((await scope.snapshot()).state == .disposed)
    }

    @Test("an owned task can dispose its own handle after it settles")
    func ownedTaskCanDisposeItsOwnHandleAfterItSettles() async throws {
        let scope = try RuntimeEffectScope(name: "task-handle-reentrant")
        let events = EventLog()
        let handleBox = HandleBox()
        let gate = AsyncGate()

        let handle = try await scope.task(label: "worker") {
            await events.record("started")
            await gate.wait()
            let report = await handleBox.dispose()
            #expect(!report.isComplete)
            await events.record("settled")
        }
        await handleBox.install(handle)
        await gate.open()
        await events.waitFor("settled")

        let report = await handle.dispose()

        #expect(report.isComplete)
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("cleanup work can request reentrant disposal without deadlocking")
    func cleanupWorkCanRequestReentrantDisposalWithoutDeadlocking() async throws {
        let scope = try RuntimeEffectScope(name: "cleanup-reentrant")
        let events = EventLog()

        _ = try await scope.add(label: "resource") {
            let report = await scope.dispose()
            #expect(!report.isComplete)
            await events.record("cleaned")
        }

        let report = await scope.dispose()

        #expect(report.isComplete)
        #expect(await events.values == ["cleaned"])
        #expect((await scope.snapshot()).state == .disposed)
    }

    @Test("unrelated disposal waits for a pending acquisition")
    func unrelatedDisposalWaitsForAPendingAcquisition() async throws {
        let scope = try RuntimeEffectScope(name: "pending-acquisition")
        let events = EventLog()
        let gate = AsyncGate()

        let acquisition = Task {
            try await scope.acquire(
                label: "resource",
                acquire: {
                    await events.record("started")
                    await gate.wait()
                    return "resource"
                },
                cleanup: { _ in await events.record("cleaned") }
            )
        }
        await events.waitFor("started")
        let disposal = Task { await scope.dispose() }
        await gate.open()
        let report = await disposal.value
        let acquired = try await acquisition.value

        #expect(acquired.value == "resource")
        #expect(report.isComplete)
        #expect(await events.values == ["started", "cleaned"])
        #expect((await scope.snapshot()).state == .disposed)
    }

    @Test("concurrent disposal callers join one cleanup operation")
    func concurrentDisposalCallersJoinOneCleanupOperation() async throws {
        let scope = try RuntimeEffectScope(name: "join-test")
        let gate = AsyncGate()
        let events = EventLog()

        _ = try await scope.add(label: "blocked") {
            await events.record("started")
            await gate.wait()
            await events.record("finished")
        }

        let first = Task { await scope.dispose() }
        await events.waitFor("started")
        let second = Task { await scope.dispose() }
        #expect(await events.values == ["started"])

        await gate.open()
        let firstReport = await first.value
        let secondReport = await second.value
        let finalReport = await scope.dispose()

        #expect(firstReport == secondReport)
        #expect(firstReport == finalReport)
        #expect(await events.values == ["started", "finished"])
    }

    @Test("early handle disposal racing scope disposal runs cleanup once")
    func earlyHandleDisposalRacingScopeDisposalRunsCleanupOnce() async throws {
        let scope = try RuntimeEffectScope(name: "handle-race")
        let gate = AsyncGate()
        let events = EventLog()
        let handle = try await scope.add(label: "owned") {
            await events.record("cleanup-started")
            await gate.wait()
            await events.record("cleanup-finished")
        }

        let handleDisposal = Task { await handle.dispose() }
        await events.waitFor("cleanup-started")
        let scopeDisposal = Task { await scope.dispose() }
        await gate.open()

        _ = await handleDisposal.value
        let report = await scopeDisposal.value

        #expect(report.isComplete)
        #expect(await events.values == ["cleanup-started", "cleanup-finished"])
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("failed acquisition rolls back earlier effects")
    func failedAcquisitionRollsBackEarlierEffects() async throws {
        let scope = try RuntimeEffectScope(name: "rollback-test")
        let events = EventLog()

        await #expect(throws: AcquisitionTestError.self) {
            try await scope.withAcquisition { scope in
                _ = try await scope.add(label: "earlier") { await events.record("earlier") }
                throw AcquisitionTestError.failed
            }
        }

        #expect(await events.values == ["earlier"])
        #expect((await scope.snapshot()).state == .active)
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("a throwing resource acquisition removes its reserved effect")
    func throwingResourceAcquisitionRemovesItsReservedEffect() async throws {
        let scope = try RuntimeEffectScope(name: "acquisition-failure")

        await #expect(throws: AcquisitionTestError.self) {
            _ = try await scope.acquire(
                label: "resource",
                acquire: { throw AcquisitionTestError.failed },
                cleanup: { _ in Issue.record("cleanup must not run for a failed acquisition") }
            )
        }

        #expect((await scope.snapshot()).state == .active)
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("transaction rollback does not remove a concurrent independent registration")
    func transactionRollbackDoesNotRemoveConcurrentIndependentRegistration() async throws {
        let scope = try RuntimeEffectScope(name: "transaction-isolation")

        await #expect(throws: AcquisitionTestError.self) {
            try await scope.withAcquisition { scope in
                _ = try await scope.add(label: "transactional") {}
                let independent = Task.detached {
                    try await scope.add(label: "independent") {}
                }
                _ = try await independent.value
                throw AcquisitionTestError.failed
            }
        }

        #expect((await scope.snapshot()).liveEffects.map(\.label) == ["independent"])
        _ = await scope.dispose()
    }

    @Test("registrations inherited by a transaction task fail after rollback closes it")
    func registrationsInheritedByATransactionTaskFailAfterRollbackClosesIt() async throws {
        let scope = try RuntimeEffectScope(name: "transaction-closed")
        let gate = AsyncGate()
        let events = EventLog()

        await #expect(throws: AcquisitionTestError.self) {
            try await scope.withAcquisition { scope in
                _ = Task {
                    await gate.wait()
                    do {
                        _ = try await scope.add(label: "late") {}
                        await events.record("accepted")
                    } catch RuntimeEffectScopeError.acquisitionClosed {
                        await events.record("rejected")
                    } catch {
                        await events.record("wrong-error")
                    }
                }
                throw AcquisitionTestError.failed
            }
        }

        await gate.open()
        await events.waitFor("rejected")
        #expect(await events.values == ["rejected"])
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("a committed transaction task can register later effects")
    func aCommittedTransactionTaskCanRegisterLaterEffects() async throws {
        let scope = try RuntimeEffectScope(name: "transaction-committed")
        let gate = AsyncGate()
        let events = EventLog()

        _ = try await scope.withAcquisition { scope in
            _ = try await scope.task(label: "worker") {
                await gate.wait()
                do {
                    _ = try await scope.add(label: "late") {}
                    await events.record("accepted")
                } catch {
                    await events.record("rejected")
                }
            }
            return ()
        }

        await gate.open()
        await events.waitFor("accepted")
        #expect((await scope.snapshot()).liveEffects.map(\.label) == ["late"])
        _ = await scope.dispose()
    }

    @Test("nested transactions do not label outer registrations with inner ownership")
    func nestedTransactionsDoNotLabelOuterRegistrationsWithInnerOwnership() async throws {
        let outer = try RuntimeEffectScope(name: "outer-transaction")
        let inner = try RuntimeEffectScope(name: "inner-transaction")
        let events = EventLog()

        _ = try await outer.task(label: "worker") {
            _ = try? await inner.withAcquisition { _ in
                _ = try await outer.add(label: "outer-resource") {}
                return ()
            }
            await events.record("settled")
        }

        await events.waitFor("settled")
        #expect((await outer.snapshot()).liveEffects.map(\.label) == ["outer-resource"])
        _ = await outer.dispose()
        _ = await inner.dispose()
    }

    @Test("ownership is reserved before acquisition can request reentrant disposal")
    func ownershipIsReservedBeforeAcquisitionCanRequestReentrantDisposal() async throws {
        let scope = try RuntimeEffectScope(name: "reentrant-test")
        let events = EventLog()

        let acquired = try await scope.acquire(
            label: "resource",
            acquire: {
                let report = await scope.dispose()
                #expect(!report.isComplete)
                return "resource"
            },
            cleanup: { resource in
                #expect(resource == "resource")
                await events.record("cleaned")
            }
        )

        #expect(acquired.value == "resource")
        #expect(await events.values == ["cleaned"])
        #expect((await scope.snapshot()).state == .disposed)
        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("registration fails after disposal begins")
    func registrationFailsAfterDisposalBegins() async throws {
        let scope = try RuntimeEffectScope(name: "registration-test")
        let gate = AsyncGate()
        let events = EventLog()
        _ = try await scope.add(label: "blocked") {
            await events.record("started")
            await gate.wait()
        }

        let disposal = Task { await scope.dispose() }
        await events.waitFor("started")
        let state = await scope.snapshot().state
        #expect(state == .disposing)
        #expect((await scope.snapshot()).liveEffects.map(\.label) == ["blocked"])
        await #expect(throws: RuntimeEffectScopeError.registrationRejected(.disposing)) {
            try await scope.add(label: "late") {}
        }

        await gate.open()
        _ = await disposal.value
        await #expect(throws: RuntimeEffectScopeError.registrationRejected(.disposed)) {
            try await scope.add(label: "later") {}
        }
    }

    @Test("cleanup failures are collected while later effects still run")
    func cleanupFailuresAreCollectedWhileLaterEffectsStillRun() async throws {
        let scope = try RuntimeEffectScope(name: "failure-test")
        let events = EventLog()

        _ = try await scope.add(label: "first") {
            await events.record("first")
            throw CleanupTestError.first
        }
        _ = try await scope.add(label: "second") {
            await events.record("second")
            throw CleanupTestError.second
        }
        _ = try await scope.add(label: "third") { await events.record("third") }

        let report = await scope.dispose()

        #expect(await events.values == ["third", "second", "first"])
        #expect(report.failures.map(\.effect.label) == ["second", "first"])
        #expect((await scope.snapshot()).cleanupFailures == report.failures)
        #expect((await scope.snapshot()).state == .disposed)
    }

    @Test("adopting a child preserves child identity and disposes it from the parent")
    func adoptingChildPreservesChildIdentityAndDisposesItFromParent() async throws {
        let parent = try RuntimeEffectScope(name: "parent")
        let child = try RuntimeEffectScope(name: "transport")
        _ = try await child.add(label: "responder") {}

        _ = try await parent.adopt(child, label: "transport-scope")
        let parentSnapshot = await parent.snapshot()
        #expect(parentSnapshot.liveEffects.first?.label == "transport-scope")
        #expect(parentSnapshot.liveEffects.first?.originScope == "transport")
        #expect((await child.snapshot()).name == "transport")

        _ = await parent.dispose()

        #expect((await child.snapshot()).state == .disposed)
        #expect((await child.snapshot()).name == "transport")
    }

    @Test("parent disposal waits through a child reentrant disposal request")
    func parentDisposalWaitsThroughAChildReentrantDisposalRequest() async throws {
        let parent = try RuntimeEffectScope(name: "reentrant-parent")
        let child = try RuntimeEffectScope(name: "reentrant-child")
        let events = EventLog()
        let gate = AsyncGate()

        _ = try await child.task(label: "worker") {
            await events.record("started")
            await gate.wait()
            let report = await parent.dispose()
            #expect(!report.isComplete)
            await events.record("parent-requested")
        }
        _ = try await parent.adopt(child, label: "child")

        let disposal = Task { await parent.dispose() }
        await events.waitFor("started")
        await gate.open()
        let report = await disposal.value

        #expect(report.isComplete)
        #expect((await parent.snapshot()).state == .disposed)
        #expect((await child.snapshot()).state == .disposed)
    }

    @Test("concurrent inverse adoption reserves only one edge")
    func concurrentInverseAdoptionReservesOnlyOneEdge() async throws {
        let first = try RuntimeEffectScope(name: "inverse-first")
        let second = try RuntimeEffectScope(name: "inverse-second")

        let firstAttempt = Task { () -> Bool in
            do {
                _ = try await first.adopt(second, label: "second")
                return true
            } catch RuntimeEffectScopeError.invalidAdoption {
                return false
            } catch {
                Issue.record("unexpected first adoption error: \(error)")
                return false
            }
        }
        let secondAttempt = Task { () -> Bool in
            do {
                _ = try await second.adopt(first, label: "first")
                return true
            } catch RuntimeEffectScopeError.invalidAdoption {
                return false
            } catch {
                Issue.record("unexpected second adoption error: \(error)")
                return false
            }
        }

        #expect((await firstAttempt.value) != (await secondAttempt.value))
        _ = await first.dispose()
        _ = await second.dispose()
    }

    @Test("self and cyclic adoption are rejected before ownership is registered")
    func selfAndCyclicAdoptionAreRejectedBeforeOwnershipIsRegistered() async throws {
        let parent = try RuntimeEffectScope(name: "adoption-parent")
        let child = try RuntimeEffectScope(name: "adoption-child")

        await #expect(throws: RuntimeEffectScopeError.invalidAdoption) {
            _ = try await parent.adopt(parent, label: "self")
        }
        _ = try await parent.adopt(child, label: "child")
        await #expect(throws: RuntimeEffectScopeError.invalidAdoption) {
            _ = try await child.adopt(parent, label: "parent")
        }

        _ = await parent.dispose()
    }

    @Test("a handle report identifies the effect it disposed")
    func handleReportIdentifiesTheEffectItDisposed() async throws {
        let scope = try RuntimeEffectScope(name: "handle-report")
        let handle = try await scope.add(label: "owned") {}

        let report = await handle.dispose()
        let repeated = await handle.dispose()

        #expect(report.attemptedEffects.map(\.label) == ["owned"])
        #expect(repeated.attemptedEffects.isEmpty)
        _ = await scope.dispose()
    }

    @Test("a handle disposed inside acquisition removes the effect immediately")
    func aHandleDisposedInsideAcquisitionRemovesTheEffectImmediately() async throws {
        let scope = try RuntimeEffectScope(name: "inline-handle")

        _ = try await scope.withAcquisition { scope in
            let handle = try await scope.add(label: "owned") {}
            let report = await handle.dispose()
            #expect(report.isComplete)
            return ()
        }

        #expect((await scope.snapshot()).liveEffects.isEmpty)
    }

    @Test("labels reject dynamic or unsafe diagnostic content")
    func labelsRejectDynamicOrUnsafeDiagnosticContent() async throws {
        #expect(throws: RuntimeEffectScopeError.invalidName) {
            try RuntimeEffectScope(name: "user prompt")
        }
        let scope = try RuntimeEffectScope(name: "label-test")
        await #expect(throws: RuntimeEffectScopeError.invalidLabel) {
            try await scope.add(label: "prompt=secret value") {}
        }
        await #expect(throws: RuntimeEffectScopeError.invalidLabel) {
            try await scope.add(label: "") {}
        }
    }

    @Test("the scope source remains a resource-only lifecycle primitive")
    func scopeSourceRemainsResourceOnly() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/RuntimeEffectScope.swift"),
            encoding: .utf8
        )

        for forbidden in [
            "NodeRegistry",
            "AscendantTurnCoordinator",
            "BackendRetirementSupervisor",
            "Axoloty",
            "PositronicKit",
            "NotificationCenter",
            "Container.resolve",
            "deinit",
        ] {
            #expect(!source.contains(forbidden), "RuntimeEffectScope must not own domain or integration authority: \(forbidden)")
        }
    }
}

private enum AcquisitionTestError: Error, Sendable {
    case failed
}

private enum CleanupTestError: Error, Sendable {
    case first
    case second
}

private actor EventLog {
    private(set) var values: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ value: String) {
        values.append(value)
        let continuations = waiters.removeValue(forKey: value) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitFor(_ value: String) async {
        if values.contains(value) { return }
        await withCheckedContinuation { continuation in
            waiters[value, default: []].append(continuation)
        }
    }
}

private actor HandleBox {
    private var handle: RuntimeEffectHandle?

    func install(_ handle: RuntimeEffectHandle) {
        self.handle = handle
    }

    func dispose() async -> RuntimeEffectCleanupReport {
        guard let handle else {
            Issue.record("the task requested its handle before the test installed it")
            return RuntimeEffectCleanupReport(
                scopeName: "missing",
                state: .active,
                attemptedEffects: [],
                failures: [],
                isComplete: false
            )
        }
        return await handle.dispose()
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
