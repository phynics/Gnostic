// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import Testing

@Suite("Ascendant turn coordination")
struct AscendantTurnCoordinatorTests {
    @Test("same id and content executes once and replays the result")
    func duplicateTurnReplays() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = TurnProbe()
        let timelineID = UUID()
        let request = AscendantTurnRequest(
            message: "hello",
            timelineID: timelineID,
            clientTurnID: "pi:session:entry-1"
        )

        let first = try await coordinator.execute(request, ascendantID: UUID()) {
            await probe.enter("first")
            await probe.leave()
            return "answer"
        }
        let replay = try await coordinator.execute(request, ascendantID: UUID()) {
            await probe.enter("duplicate")
            await probe.leave()
            return "wrong answer"
        }

        #expect(first.clientTurnID == request.clientTurnID)
        #expect(first.text == "answer")
        #expect(!first.replayed)
        #expect(replay.clientTurnID == request.clientTurnID)
        #expect(replay.text == "answer")
        #expect(replay.replayed)
        #expect(await probe.starts == 1)
    }

    @Test("reusing an id with different content is rejected before execution")
    func conflictingTurnIsRejected() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = TurnProbe()
        let timelineID = UUID()
        let firstRequest = AscendantTurnRequest(message: "first", timelineID: timelineID, clientTurnID: "turn-1")
        let conflictRequest = AscendantTurnRequest(message: "different", timelineID: timelineID, clientTurnID: "turn-1")

        _ = try await coordinator.execute(firstRequest, ascendantID: UUID()) {
            await probe.enter("first")
            await probe.leave()
            return "answer"
        }

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(conflictRequest, ascendantID: UUID()) {
                await probe.enter("conflict")
                await probe.leave()
                return "must not run"
            }
        }
        #expect(await probe.starts == 1)
    }

    @Test("turns on one Timeline serialize while different Timelines run in parallel")
    func timelineLanes() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = TurnProbe()
        let timelineID = UUID()
        let firstRequest = AscendantTurnRequest(message: "first", timelineID: timelineID, clientTurnID: "turn-1")
        let secondRequest = AscendantTurnRequest(message: "second", timelineID: timelineID, clientTurnID: "turn-2")
        let otherRequest = AscendantTurnRequest(message: "other", timelineID: UUID(), clientTurnID: "turn-3")

        let first = Task {
            try await coordinator.execute(firstRequest, ascendantID: UUID()) {
                await probe.enter("first")
                // Hold this lane until the independent Timeline has actually
                // entered, instead of relying on scheduler timing.
                await probe.waitForStarts(2)
                await probe.leave()
                return "first"
            }
        }
        await probe.waitForStarts(1)

        let second = Task {
            try await coordinator.execute(secondRequest, ascendantID: UUID()) {
                await probe.enter("second")
                await probe.leave()
                return "second"
            }
        }
        let other = Task {
            try await coordinator.execute(otherRequest, ascendantID: UUID()) {
                await probe.enter("other")
                await probe.leave()
                return "other"
            }
        }

        _ = try await (first.value, second.value, other.value)
        #expect(await probe.maxActive == 2)
        #expect(await probe.order == ["first", "other", "second"])
    }

    @Test("legacy turns without ids still share the Timeline lane")
    func legacyTurnsSerialize() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = TurnProbe()
        let timelineID = UUID()
        let firstRequest = AscendantTurnRequest(message: "first", timelineID: timelineID)
        let secondRequest = AscendantTurnRequest(message: "second", timelineID: timelineID)

        let first = Task {
            try await coordinator.execute(firstRequest, ascendantID: UUID()) {
                await probe.enter("first")
                try await Task.sleep(for: .milliseconds(80))
                await probe.leave()
                return "first"
            }
        }
        await probe.waitForStarts(1)
        let second = Task {
            try await coordinator.execute(secondRequest, ascendantID: UUID()) {
                await probe.enter("second")
                await probe.leave()
                return "second"
            }
        }

        _ = try await (first.value, second.value)
        #expect(await probe.maxActive == 1)
        #expect(await probe.order == ["first", "second"])
    }

    @Test("canceling a caller does not duplicate an admitted turn")
    func lostCallerDoesNotRetryTheTurn() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = TurnProbe()
        let request = AscendantTurnRequest(message: "once", timelineID: UUID(), clientTurnID: "turn-cancelled")

        let caller = Task {
            try await coordinator.execute(request, ascendantID: UUID()) {
                await probe.enter("original")
                try await Task.sleep(for: .milliseconds(100))
                await probe.leave()
                return "completed"
            }
        }
        await probe.waitForStarts(1)
        caller.cancel()

        let replay = try await coordinator.execute(request, ascendantID: UUID()) {
            await probe.enter("retry")
            await probe.leave()
            return "must not run"
        }
        _ = try? await caller.value

        #expect(replay.text == "completed")
        #expect(replay.replayed)
        #expect(await probe.starts == 1)
    }

    @Test("failed and cancelled turns remain terminal and are not retried")
    func terminalFailuresAreCached() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = TurnProbe()
        let failedRequest = AscendantTurnRequest(message: "fails", timelineID: UUID(), clientTurnID: "turn-fails")
        let cancelledRequest = AscendantTurnRequest(message: "cancels", timelineID: UUID(), clientTurnID: "turn-cancels")

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(failedRequest, ascendantID: UUID()) {
                await probe.enter("failed")
                throw TestTurnError.failed
            }
        }
        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(failedRequest, ascendantID: UUID()) {
                await probe.enter("failed-retry")
                return "must not run"
            }
        }

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(cancelledRequest, ascendantID: UUID()) {
                await probe.enter("cancelled")
                throw CancellationError()
            }
        }
        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(cancelledRequest, ascendantID: UUID()) {
                await probe.enter("cancelled-retry")
                return "must not run"
            }
        }

        #expect(await probe.starts == 2)
    }

    @Test("backend terminal metadata survives coordination")
    func backendTerminalMetadataIsPreserved() async throws {
        let coordinator = AscendantTurnCoordinator()
        let request = AscendantTurnRequest(message: "fails", timelineID: UUID(), clientTurnID: "turn-terminal")

        do {
            _ = try await coordinator.execute(request, ascendantID: UUID()) {
                throw AscendantBackendError.terminal(.init(code: "providerUnavailable", message: "provider is offline", retryable: true))
            }
            Issue.record("The terminal backend failure unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error.reasonCode == "providerUnavailable")
            #expect(error.retryable)
            #expect(error.localizedDescription == "provider is offline")
        }
    }

    @Test("backend domain status survives coordinator caching")
    func backendDomainStatusCodesArePreserved() async throws {
        let failures: [(String, AscendantBackendError, Int, String)] = [
            ("invalid", .invalidConfiguration("secret invalid configuration"), 400, "invalidConfiguration"),
            ("missing", .timelineNotFound(UUID()), 404, "timelineNotFound"),
            ("lifecycle", .lifecycleUnusable(.init(code: "lifecycleDown", message: "secret lifecycle detail")), 503, "backendLifecycleUnusable")
        ]
        for (id, backendError, status, reason) in failures {
            let coordinator = AscendantTurnCoordinator()
            let request = AscendantTurnRequest(message: id, timelineID: UUID(), clientTurnID: id)
            do {
                _ = try await coordinator.execute(request, ascendantID: UUID()) { throw backendError }
                Issue.record("The backend failure unexpectedly succeeded: \(id)")
            } catch let error as AscendantTurnError {
                #expect(error.statusCode == status)
                #expect(error.reasonCode == reason)
                #expect(error.statusCode == status)
                await #expect(throws: AscendantTurnError.self) {
                _ = try await coordinator.execute(request, ascendantID: UUID()) { "must not rerun" }
                }
            }
        }
    }

    @Test("capacity rejects a new identity before operation admission")
    func identityCapacityRejectsBeforeOperation() async throws {
        let coordinator = AscendantTurnCoordinator(completedCapacity: 1, identityCapacity: 2)
        let probe = TurnProbe()
        for index in 0..<2 {
            let request = AscendantTurnRequest(
                message: "message-\(index)",
                timelineID: UUID(),
                clientTurnID: "admitted-\(index)"
            )
            _ = try await coordinator.execute(request, ascendantID: UUID()) {
                await probe.enter("admitted-\(index)")
                return "answer-\(index)"
            }
        }

        let rejected = AscendantTurnRequest(
            message: "not admitted",
            timelineID: UUID(),
            clientTurnID: "rejected"
        )
        do {
            _ = try await coordinator.execute(rejected, ascendantID: UUID()) {
                await probe.enter("rejected")
                return "must not run"
            }
            Issue.record("A new identity was admitted after the identity ledger reached capacity.")
        } catch let error as AscendantTurnError {
            #expect(error == .capacityExceeded(timelineID: rejected.timelineID, clientTurnID: "rejected"))
        }
        #expect(await probe.starts == 2)
        #expect(await coordinator.retainedIdentityCount == 2)
    }

    @Test("retained terminal errors have a bounded completed payload")
    func retainedTerminalErrorsAreBounded() async throws {
        let completedCapacity = 2
        let coordinator = AscendantTurnCoordinator(completedCapacity: completedCapacity, identityCapacity: 2)
        let huge = String(repeating: "x", count: 100_000)
        let request = AscendantTurnRequest(message: "failure", timelineID: UUID(), clientTurnID: "huge-error")

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(request, ascendantID: UUID()) {
                throw AscendantBackendError.terminal(.init(code: huge, message: huge))
            }
        }

        let counts = await coordinator.retainedStateCounts
        #expect(counts.completed == 1)
        #expect(counts.completedBytes <= completedCapacity * GnosticWirePayload.maximumEmbeddedValueBytes)
    }

    @Test("newer evicted identities remain conflict-checked and non-retryable")
    func newerEvictedIdentitiesNeverRerun() async throws {
        let coordinator = AscendantTurnCoordinator(completedCapacity: 1, identityCapacity: 3)
        let probe = TurnProbe()
        var requests: [AscendantTurnRequest] = []
        for index in 0..<3 {
            let request = AscendantTurnRequest(
                message: "message-\(index)",
                timelineID: UUID(),
                clientTurnID: "evicted-\(index)"
            )
            requests.append(request)
            _ = try await coordinator.execute(request, ascendantID: UUID()) {
                await probe.enter("evicted-\(index)")
                return "answer-\(index)"
            }
        }

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(requests[1], ascendantID: UUID()) {
                await probe.enter("rerun")
                return "must not run"
            }
        }
        let conflict = AscendantTurnRequest(
            message: "different",
            timelineID: requests[1].timelineID,
            clientTurnID: requests[1].clientTurnID
        )
        do {
            _ = try await coordinator.execute(conflict, ascendantID: UUID()) {
                await probe.enter("conflict")
                return "must not run"
            }
            Issue.record("An evicted identity was accepted with different content.")
        } catch let error as AscendantTurnError {
            #expect(error == .conflict(timelineID: conflict.timelineID, clientTurnID: conflict.clientTurnID!))
        }
        #expect(await probe.starts == 3)
    }

    @Test("evicted results retain a non-retryable identity tombstone")
    func evictedResultsNeverRerun() async throws {
        let coordinator = AscendantTurnCoordinator(completedCapacity: 1)
        let probe = TurnProbe()
        let first = AscendantTurnRequest(message: "first", timelineID: UUID(), clientTurnID: "turn-1")
        let second = AscendantTurnRequest(message: "second", timelineID: UUID(), clientTurnID: "turn-2")

        _ = try await coordinator.execute(first, ascendantID: UUID()) {
            await probe.enter("first")
            return "one"
        }
        _ = try await coordinator.execute(second, ascendantID: UUID()) {
            await probe.enter("second")
            return "two"
        }

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(first, ascendantID: UUID()) {
                await probe.enter("rerun")
                return "must not run"
            }
        }
        #expect(await probe.starts == 2)
    }
}

    @Test("completed coordinator state is globally retained within its bound")
    func completedStateIsGloballyBounded() async throws {
        let coordinator = AscendantTurnCoordinator(completedCapacity: 2, identityCapacity: 8)
        for index in 0..<8 {
            let request = AscendantTurnRequest(message: "message-\(index)", timelineID: UUID(), clientTurnID: "turn-\(index)")
            _ = try await coordinator.execute(request, ascendantID: UUID()) { "answer-\(index)" }
        }

        let counts = await coordinator.retainedStateCounts
        #expect(counts.completed <= 2)
        #expect(counts.tombstones <= 8)
        #expect(counts.identities == 8)
    }

    @Test("completed Timeline lanes are removed after their operation finishes")
    func completedTimelineLanesAreCleanedUp() async throws {
        let coordinator = AscendantTurnCoordinator()
        for _ in 0..<24 {
            let request = AscendantTurnRequest(message: "lane", timelineID: UUID())
            _ = try await coordinator.execute(request, ascendantID: UUID()) { "done" }
        }

        #expect(await coordinator.retainedTimelineCount == 0)
    }

    @Test("cancelling queued work skips its backend operation")
    func queuedCancellationSkipsBackend() async throws {
        let coordinator = AscendantTurnCoordinator()
        let gate = TurnGate()
        let probe = TurnProbe()
        let timelineID = UUID()
        let firstRequest = AscendantTurnRequest(message: "first", timelineID: timelineID, clientTurnID: "first")
        let queuedRequest = AscendantTurnRequest(message: "queued", timelineID: timelineID, clientTurnID: "queued")

        let first = Task {
            try await coordinator.execute(firstRequest, ascendantID: UUID()) {
                await probe.enter("first")
                await gate.wait()
                try Task.checkCancellation()
                return "first"
            }
        }
        await probe.waitForStarts(1)
        let queued = Task {
            try await coordinator.execute(queuedRequest, ascendantID: UUID()) {
                await probe.enter("queued")
                return "must-not-run"
            }
        }
        for _ in 0..<100 {
            if await coordinator.inFlightCount == 2 { break }
            await Task.yield()
        }
        #expect(await coordinator.inFlightCount == 2)

        await coordinator.cancelAll(waitForCompletion: false)
        await gate.release()
        _ = try? await first.value
        _ = try? await queued.value
        #expect(await probe.order == ["first"])
    }

    @Test("original success is observed once with stable identity after replay commit")
    func originalSuccessIsObservedOnce() async throws {
        let timelineID = UUID()
        let ascendantID = UUID()
        let request = AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: "turn-observed")
        let replayCheck = ObservationReplayCheck(request: request)
        let observer = TerminalTurnObservationProbe { record in
            await replayCheck.check(record)
        }
        let coordinator = AscendantTurnCoordinator(observers: [observer])
        await replayCheck.install(coordinator: coordinator)

        let first = try await coordinator.execute(request, ascendantID: ascendantID) { "answer" }
        await observer.waitForRecords(1)
        await replayCheck.waitForCheck()
        let replay = try await coordinator.execute(request, ascendantID: ascendantID) { "must-not-run" }

        let records = await observer.records
        #expect(first.text == "answer")
        #expect(replay.replayed)
        #expect(records.count == 1)
        #expect(records[0].operationID.isEmpty == false)
        #expect(records[0].ascendantID == ascendantID)
        #expect(records[0].clientTurnID == request.clientTurnID)
        #expect(await replayCheck.sawCommittedReplay)
    }

    @Test("unidentified admitted turns receive distinct stable observation identities")
    func unidentifiedTurnsReceiveOperationIdentity() async throws {
        let observer = TerminalTurnObservationProbe()
        let coordinator = AscendantTurnCoordinator(observers: [observer])
        let ascendantID = UUID()

        _ = try await coordinator.execute(.init(message: "one", timelineID: UUID()), ascendantID: ascendantID) { "one" }
        _ = try await coordinator.execute(.init(message: "two", timelineID: UUID()), ascendantID: ascendantID) { "two" }
        await observer.waitForRecords(2)

        let records = await observer.records
        #expect(records.count == 2)
        #expect(records.allSatisfy { !$0.operationID.isEmpty })
        #expect(Set(records.map(\.operationID)).count == 2)
        #expect(records.allSatisfy { $0.clientTurnID == nil })
    }

    @Test("tombstone state is committed before the terminal observation")
    func tombstoneCommitPrecedesObservation() async throws {
        let first = AscendantTurnRequest(message: "first", timelineID: UUID(), clientTurnID: "first")
        let second = AscendantTurnRequest(message: "second", timelineID: UUID(), clientTurnID: "second")
        let check = ObservationTombstoneCheck(request: first)
        let observer = TerminalTurnObservationProbe { record in
            await check.check(record)
        }
        let coordinator = AscendantTurnCoordinator(completedCapacity: 1, observers: [observer])
        await check.install(coordinator: coordinator)

        _ = try await coordinator.execute(first, ascendantID: UUID()) { "one" }
        _ = try await coordinator.execute(second, ascendantID: UUID()) { "two" }
        await check.waitForTombstone()

        #expect(await check.sawCommittedTombstone)
    }

    @Test("structured failures and cancellation each produce one terminal observation")
    func failuresAndCancellationAreObserved() async throws {
        let observer = TerminalTurnObservationProbe()
        let coordinator = AscendantTurnCoordinator(observers: [observer])
        let ascendantID = UUID()
        let failureRequest = AscendantTurnRequest(message: "failure", timelineID: UUID(), clientTurnID: "failure")
        let cancellationRequest = AscendantTurnRequest(message: "cancel", timelineID: UUID(), clientTurnID: "cancel")

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(failureRequest, ascendantID: ascendantID) {
                throw AscendantBackendError.terminal(.init(code: "providerUnavailable", message: "offline", retryable: true))
            }
        }
        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(cancellationRequest, ascendantID: ascendantID) {
                throw CancellationError()
            }
        }
        await observer.waitForRecords(2)

        let outcomes = await observer.records.map(\.outcome)
        #expect(outcomes.contains(.failed(.init(reasonCode: "providerUnavailable", statusCode: 500, retryable: true))))
        #expect(outcomes.contains(.cancelled))
    }

    @Test("duplicates, replay, tombstones, conflicts, and pre-admission failures are not observed")
    func nonOriginalRequestsAreNotObserved() async throws {
        let observer = TerminalTurnObservationProbe()
        let coordinator = AscendantTurnCoordinator(completedCapacity: 1, identityCapacity: 2, observers: [observer])
        let timelineID = UUID()
        let request = AscendantTurnRequest(message: "same", timelineID: timelineID, clientTurnID: "same")
        let conflict = AscendantTurnRequest(message: "different", timelineID: timelineID, clientTurnID: "same")
        let gate = TurnGate()
        let probe = TurnProbe()

        let original = Task {
            try await coordinator.execute(request, ascendantID: UUID()) {
                await probe.enter("original")
                await gate.wait()
                return "answer"
            }
        }
        await probe.waitForStarts(1)
        let duplicate = Task {
            try await coordinator.execute(request, ascendantID: UUID()) { "must-not-run" }
        }
        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(conflict, ascendantID: UUID()) { "must-not-run" }
        }
        await gate.release()
        _ = try await original.value
        _ = try await duplicate.value
        await observer.waitForRecords(1)

        let second = AscendantTurnRequest(message: "second", timelineID: UUID(), clientTurnID: "second")
        _ = try await coordinator.execute(second, ascendantID: UUID()) { "second" }
        await observer.waitForRecords(2)
        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(request, ascendantID: UUID()) { "must-not-rerun" }
        }
        let replay = try await coordinator.execute(second, ascendantID: UUID()) { "must-not-rerun" }
        #expect(replay.replayed)

        let rejected = AscendantTurnRequest(message: "rejected", timelineID: UUID(), clientTurnID: "rejected")
        do {
            _ = try await coordinator.execute(rejected, ascendantID: UUID()) { "must-not-run" }
            Issue.record("The capacity rejection unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error == .capacityExceeded(timelineID: rejected.timelineID, clientTurnID: "rejected"))
        }
        #expect(await observer.records.count == 2)

        let incompatible = AscendantTurnRequest(
            message: "incompatible",
            timelineID: UUID(),
            clientTurnID: "incompatible",
            protocolMajor: 1
        )
        await #expect(throws: GnosticProtocolError.self) {
            _ = try await coordinator.execute(incompatible, ascendantID: UUID()) { "must-not-run" }
        }
        #expect(await observer.records.count == 2)
    }

    @Test("observer failures are contained and later observers still receive the record")
    func observerFailuresAreContained() async throws {
        let order = ObservationOrder()
        let failing = TerminalTurnObservationProbe(label: "failing", order: order, fails: true)
        let succeeding = TerminalTurnObservationProbe(label: "succeeding", order: order)
        let coordinator = AscendantTurnCoordinator(observers: [failing, succeeding])
        let request = AscendantTurnRequest(message: "hello", timelineID: UUID(), clientTurnID: "observer-failure")

        let result = try await coordinator.execute(request, ascendantID: UUID()) { "answer" }
        await succeeding.waitForRecords(1)

        #expect(result.text == "answer")
        #expect(await failing.records.count == 1)
        #expect(await succeeding.records.count == 1)
        #expect(await order.values == ["failing", "succeeding"])
    }

    @Test("a backend that ignores cancellation still commits and observes its real outcome")
    func cancelIgnoredByBackendKeepsRealOutcome() async throws {
        let observer = TerminalTurnObservationProbe()
        let coordinator = AscendantTurnCoordinator(observers: [observer])
        let gate = TurnGate()
        let probe = TurnProbe()
        let ascendantID = UUID()
        let request = AscendantTurnRequest(message: "applied", timelineID: UUID(), clientTurnID: "applied")

        let cancelObserved = CompletionFlag()
        let turn = Task {
            try await coordinator.execute(request, ascendantID: ascendantID) {
                await probe.enter("original")
                // Observe cancellation only to synchronize the test; the
                // backend still applies the Turn instead of throwing.
                while !Task.isCancelled { await Task.yield() }
                await cancelObserved.mark()
                await gate.wait()
                return "applied"
            }
        }
        await probe.waitForStarts(1)
        let shutdown = Task { await coordinator.cancelAll() }
        while !(await cancelObserved.value) { await Task.yield() }
        await gate.release()
        let result = try await turn.value
        await shutdown.value
        await observer.waitForRecords(1)

        let records = await observer.records
        #expect(result.text == "applied")
        #expect(!result.replayed)
        #expect(records.count == 1)
        #expect(records[0].outcome == .succeeded)
        #expect(records[0].operationID.isEmpty == false)
        let counts = await coordinator.retainedStateCounts
        #expect(counts.completed == 1)
    }

    @Test("bounded shutdown fences a turn that outlives the settle window")
    func boundedShutdownFencesLateTerminalObservation() async throws {
        // TurnGate.wait() is not cancellable, so this turn models a backend
        // that ignores cancellation: it is still running when the settle
        // window expires and is therefore cut off by the fence. The 50ms
        // bound only limits test duration; the assertions are on state.
        let observer = TerminalTurnObservationProbe()
        let coordinator = AscendantTurnCoordinator(
            observers: [observer],
            observationDrainTimeout: .milliseconds(50)
        )
        let gate = TurnGate()
        let probe = TurnProbe()
        let timelineID = UUID()
        let ascendantID = UUID()

        let turn = Task {
            try await coordinator.execute(
                .init(message: "late", timelineID: timelineID),
                ascendantID: ascendantID
            ) {
                await probe.enter("original")
                await gate.wait()
                return "late-result"
            }
        }
        await probe.waitForStarts(1)
        await coordinator.cancelAll(waitForCompletion: false)
        await gate.release()
        let result = try await turn.value

        let records = await observer.records
        #expect(result.text == "late-result")
        #expect(records.isEmpty)
    }

    @Test("bounded shutdown observes a turn that honours cancellation")
    func boundedShutdownObservesCooperativeTurn() async throws {
        let observer = TerminalTurnObservationProbe()
        let coordinator = AscendantTurnCoordinator(observers: [observer])
        let probe = TurnProbe()
        let timelineID = UUID()

        let turn = Task {
            try await coordinator.execute(
                .init(message: "cooperative", timelineID: timelineID, clientTurnID: "cooperative"),
                ascendantID: UUID()
            ) {
                await probe.enter("original")
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            }
        }
        await probe.waitForStarts(1)

        // The bounded path cancels, then waits for settlement before closing
        // the fence, so this turn is admitted for observation.
        await coordinator.cancelAll(waitForCompletion: false)

        await #expect(throws: AscendantTurnError.self) { _ = try await turn.value }
        let records = await observer.records
        // #require keeps a regression failing cleanly instead of trapping on
        // an empty collection.
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.outcome == .cancelled)
        #expect(record.clientTurnID == "cooperative")
    }

    @Test("overlapping bounded shutdowns both complete")
    func overlappingBoundedShutdownsComplete() async throws {
        let coordinator = AscendantTurnCoordinator(observationDrainTimeout: .milliseconds(50))
        let gate = TurnGate()
        let probe = TurnProbe()

        let turn = Task {
            try await coordinator.execute(
                .init(message: "late", timelineID: UUID()),
                ascendantID: UUID()
            ) {
                await probe.enter("original")
                await gate.wait()
                return "late-result"
            }
        }
        await probe.waitForStarts(1)

        let finished = CompletionFlag()
        Task {
            async let first: Void = coordinator.cancelAll(waitForCompletion: false)
            async let second: Void = coordinator.cancelAll(waitForCompletion: false)
            _ = await (first, second)
            await finished.mark()
        }
        // Poll rather than join: a shutdown whose settle continuation was
        // stranded by the overlapping call must fail this test, not hang it.
        for _ in 0..<200 {
            if await finished.value { break }
            try? await Task.sleep(for: .milliseconds(25))
        }

        #expect(await finished.value)
        await gate.release()
        _ = try? await turn.value
    }

    @Test("bounded shutdown does not wait for a contract-violating stuck observer")
    func boundedShutdownReleasesStuckObserver() async throws {
        // stuckSleep suspends in *cancellable* Task.sleep: the drain bound
        // (50ms here) cuts the wait, then scope disposal cancels the stuck
        // delivery and shutdown completes. The bound only limits test
        // duration; the test asserts post-conditions, never elapsed time.
        // A non-cancellable infinite wait would hang disposal itself, which
        // the observer contract forbids.
        let observer = TerminalTurnObservationProbe(stuckSleep: .seconds(3_600))
        let coordinator = AscendantTurnCoordinator(
            observers: [observer],
            observationDrainTimeout: .milliseconds(50)
        )
        let request = AscendantTurnRequest(message: "hello", timelineID: UUID(), clientTurnID: "stuck-observer")

        _ = try await coordinator.execute(request, ascendantID: UUID()) { "answer" }
        await observer.waitForRecords(1)
        await coordinator.cancelAll()

        #expect(await observer.records.count == 1)
        #expect((await coordinator.observationSnapshot()).state == .disposed)
    }

    @Test("shutdown awaits owned observation work before returning")
    func shutdownReachesObservationQuiescence() async throws {
        let gate = TurnGate()
        let observer = TerminalTurnObservationProbe(gate: gate)
        let coordinator = AscendantTurnCoordinator(observers: [observer])
        let request = AscendantTurnRequest(message: "hello", timelineID: UUID(), clientTurnID: "shutdown")

        _ = try await coordinator.execute(request, ascendantID: UUID()) { "answer" }
        await observer.waitForRecords(1)

        let shutdownFinished = CompletionFlag()
        let shutdown = Task {
            await coordinator.cancelAll()
            await shutdownFinished.mark()
        }
        await Task.yield()
        #expect(!(await shutdownFinished.value))

        await gate.release()
        await shutdown.value
        #expect(await shutdownFinished.value)
        #expect((await coordinator.observationSnapshot()).state == .disposed)
    }


private enum TestTurnError: Error {
    case failed
}

private actor TurnProbe {
    private(set) var starts = 0
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var order: [String] = []

    func enter(_ label: String) {
        starts += 1
        active += 1
        maxActive = max(maxActive, active)
        order.append(label)
    }

    func leave() {
        active -= 1
    }

    func waitForStarts(_ expected: Int) async {
        for _ in 0..<100 {
            if starts >= expected { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}


private actor TurnGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor ObservationReplayCheck {
    private var coordinator: AscendantTurnCoordinator?
    private let request: AscendantTurnRequest
    private(set) var sawCommittedReplay = false
    private var didCheck = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(request: AscendantTurnRequest) {
        self.request = request
    }

    func install(coordinator: AscendantTurnCoordinator) {
        self.coordinator = coordinator
    }

    func check(_ record: TerminalTurnRecord) async {
        defer { finishCheck() }
        guard record.clientTurnID == request.clientTurnID, let coordinator else { return }
        do {
            let replay = try await coordinator.execute(request, ascendantID: record.ascendantID) { "must-not-run" }
            sawCommittedReplay = replay.replayed
        } catch {
            sawCommittedReplay = false
        }
    }

    private func finishCheck() {
        didCheck = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForCheck() async {
        if didCheck { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor ObservationTombstoneCheck {
    private var coordinator: AscendantTurnCoordinator?
    private let request: AscendantTurnRequest
    private(set) var sawCommittedTombstone = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(request: AscendantTurnRequest) {
        self.request = request
    }

    func install(coordinator: AscendantTurnCoordinator) {
        self.coordinator = coordinator
    }

    func check(_ record: TerminalTurnRecord) async {
        guard record.clientTurnID == "second", let coordinator else { return }
        do {
            _ = try await coordinator.execute(request, ascendantID: record.ascendantID) { "must-not-run" }
        } catch let error as AscendantTurnError {
            sawCommittedTombstone = error == .replayUnavailable(
                timelineID: request.timelineID,
                clientTurnID: request.clientTurnID ?? ""
            )
        } catch {
            sawCommittedTombstone = false
        }
        waiter?.resume()
        waiter = nil
    }

    func waitForTombstone() async {
        if sawCommittedTombstone { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private actor TerminalTurnObservationProbe: TerminalTurnObserving {
    let label: String?
    let order: ObservationOrder?
    let fails: Bool
    let gate: TurnGate?
    let sleepsFirst: Bool
    let stuckSleep: Duration?
    private(set) var records: [TerminalTurnRecord] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(label: String? = nil, order: ObservationOrder? = nil, fails: Bool = false, gate: TurnGate? = nil, sleepsFirst: Bool = false, stuckSleep: Duration? = nil) {
        self.label = label
        self.order = order
        self.fails = fails
        self.gate = gate
        self.sleepsFirst = sleepsFirst
        self.stuckSleep = stuckSleep
        self.onObserve = nil
    }

    init(_ onObserve: @escaping @Sendable (TerminalTurnRecord) async -> Void) {
        label = nil
        order = nil
        fails = false
        gate = nil
        sleepsFirst = false
        stuckSleep = nil
        self.onObserve = onObserve
    }

    private var onObserve: (@Sendable (TerminalTurnRecord) async -> Void)?

    func observe(_ record: TerminalTurnRecord) async throws {
        // Cancellable work: aborts immediately when the observer inherits a
        // cancelled task context, which is exactly what the late-delivery
        // isolation must prevent.
        if sleepsFirst { try await Task.sleep(for: .milliseconds(10)) }
        records.append(record)
        let continuations = waiters.removeValue(forKey: records.count) ?? []
        continuations.forEach { $0.resume() }
        if let stuckSleep { try await Task.sleep(for: stuckSleep) }
        if let label, let order { await order.append(label) }
        if let onObserve { await onObserve(record) }
        if let gate { await gate.wait() }
        if fails { throw TestObserverError.failed }
    }

    func waitForRecords(_ expected: Int) async {
        guard records.count < expected else { return }
        await withCheckedContinuation { continuation in
            waiters[expected, default: []].append(continuation)
        }
    }
}

private enum TestObserverError: Error, Sendable {
    case failed
}

private actor ObservationOrder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor CompletionFlag {
    private(set) var value = false

    func mark() {
        value = true
    }
}
