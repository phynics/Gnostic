// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import GnosticProtocol
import Testing

/// ADR 0021 "Turn semantics": at most one active foreground Turn per Timeline.
/// A distinct Turn that arrives while another is active is rejected before it
/// reaches the backend; it is not queued and not admitted.
@Suite("Turn busy admission")
struct TurnBusyAdmissionTests {
    @Test("a distinct Turn on a busy Timeline is rejected with timelineBusy and never reaches the backend")
    func distinctTurnIsRejectedBeforeDispatch() async throws {
        let coordinator = AscendantTurnCoordinator()
        let gate = BusyGate()
        let probe = BusyProbe()
        let timelineID = UUID()
        let active = Task {
            try await coordinator.execute(
                TurnRequest(message: "first", timelineID: timelineID, clientTurnID: "busy-first"),
                ascendantID: UUID()
            ) {
                await probe.enter("first")
                await gate.wait()
                return "first"
            }
        }
        await probe.waitForStarts(1)

        let rejected = await BusyOutcome.settle {
            try await coordinator.execute(
                TurnRequest(message: "second", timelineID: timelineID, clientTurnID: "busy-second"),
                ascendantID: UUID()
            ) {
                await probe.enter("second")
                return "second"
            }
        }
        // Release the active Turn before asserting, so a regression that queues
        // the second Turn cannot leave the suite hanging.
        await gate.release()
        _ = try await active.value

        guard case let .failure(error)? = rejected, let busy = error as? TurnError else {
            Issue.record("Expected an immediate timelineBusy rejection, observed \(String(describing: rejected)).")
            return
        }
        #expect(busy.reasonCode == "timelineBusy")
        #expect(busy.statusCode == 409)
        #expect(busy.retryable)
        #expect(await probe.order == ["first"])
    }

    @Test("a busy rejection admits nothing, so the same request runs once the Timeline is idle")
    func rejectedTurnCanBeRetriedAfterTheActiveTurnEnds() async throws {
        let coordinator = AscendantTurnCoordinator()
        let gate = BusyGate()
        let probe = BusyProbe()
        let timelineID = UUID()
        let activeRequest = TurnRequest(message: "first", timelineID: timelineID, clientTurnID: "retry-first")
        let rejectedRequest = TurnRequest(message: "second", timelineID: timelineID, clientTurnID: "retry-second")
        let active = Task {
            try await coordinator.execute(activeRequest, ascendantID: UUID()) {
                await probe.enter("first")
                await gate.wait()
                return "first"
            }
        }
        await probe.waitForStarts(1)

        let rejected = await BusyOutcome.settle {
            try await coordinator.execute(rejectedRequest, ascendantID: UUID()) {
                await probe.enter("rejected")
                return "rejected"
            }
        }
        #expect(await coordinator.retainedIdentityCount == 1)
        await gate.release()
        _ = try await active.value
        guard case .failure? = rejected else {
            Issue.record("The distinct Turn was not rejected while the Timeline was busy.")
            return
        }

        let retried = try await coordinator.execute(rejectedRequest, ascendantID: UUID()) {
            await probe.enter("retry")
            return "second"
        }
        #expect(retried.text == "second")
        #expect(!retried.replayed)
        #expect(await probe.order == ["first", "retry"])
    }

    @Test("an identical retry of the active Turn attaches to it instead of being rejected")
    func identicalRetryAttachesToTheActiveTurn() async throws {
        let coordinator = AscendantTurnCoordinator()
        let gate = BusyGate()
        let probe = BusyProbe()
        let request = TurnRequest(message: "first", timelineID: UUID(), clientTurnID: "attach-first")
        let active = Task {
            try await coordinator.execute(request, ascendantID: UUID()) {
                await probe.enter("first")
                await gate.wait()
                return "answer"
            }
        }
        await probe.waitForStarts(1)
        let attached = Task {
            try await coordinator.execute(request, ascendantID: UUID()) {
                await probe.enter("duplicate")
                return "must not run"
            }
        }
        // Give the duplicate time to reach the coordinator while the Turn is held.
        try await Task.sleep(for: .milliseconds(100))
        await gate.release()

        let original = try await active.value
        let retry = try await attached.value
        #expect(original.text == "answer")
        #expect(retry.text == "answer")
        #expect(retry.replayed)
        #expect(await probe.order == ["first"])
    }

    @Test("a replayed completed Turn is answered while another Turn is active on the Timeline")
    func completedReplayIsNotBusy() async throws {
        let coordinator = AscendantTurnCoordinator()
        let gate = BusyGate()
        let probe = BusyProbe()
        let timelineID = UUID()
        let completed = TurnRequest(message: "done", timelineID: timelineID, clientTurnID: "replay-done")
        _ = try await coordinator.execute(completed, ascendantID: UUID()) { "done" }
        let active = Task {
            try await coordinator.execute(
                TurnRequest(message: "active", timelineID: timelineID, clientTurnID: "replay-active"),
                ascendantID: UUID()
            ) {
                await probe.enter("active")
                await gate.wait()
                return "active"
            }
        }
        await probe.waitForStarts(1)

        let replay = await BusyOutcome.settle {
            try await coordinator.execute(completed, ascendantID: UUID()) { "must not run" }
        }
        await gate.release()
        _ = try await active.value

        guard case let .success(result)? = replay else {
            Issue.record("A completed Turn's replay was refused while the Timeline was busy: \(String(describing: replay)).")
            return
        }
        #expect(result.replayed)
        #expect(result.text == "done")
    }

    @Test("a legacy Turn without an id is rejected while the Timeline is busy")
    func legacyTurnIsRejectedWhileBusy() async throws {
        let coordinator = AscendantTurnCoordinator()
        let gate = BusyGate()
        let probe = BusyProbe()
        let timelineID = UUID()
        let active = Task {
            try await coordinator.execute(
                TurnRequest(message: "first", timelineID: timelineID),
                ascendantID: UUID()
            ) {
                await probe.enter("first")
                await gate.wait()
                return "first"
            }
        }
        await probe.waitForStarts(1)
        let rejected = await BusyOutcome.settle {
            try await coordinator.execute(
                TurnRequest(message: "second", timelineID: timelineID),
                ascendantID: UUID()
            ) {
                await probe.enter("second")
                return "second"
            }
        }
        await gate.release()
        _ = try await active.value

        guard case let .failure(error)? = rejected, let busy = error as? TurnError else {
            Issue.record("Expected a timelineBusy rejection for the legacy Turn, observed \(String(describing: rejected)).")
            return
        }
        #expect(busy.reasonCode == "timelineBusy")
        #expect(await probe.order == ["first"])
    }

    @Test("different Timelines run in parallel while a busy Timeline rejects")
    func differentTimelinesRunInParallel() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = BusyProbe()
        let busyTimeline = UUID()
        let first = Task {
            try await coordinator.execute(
                TurnRequest(message: "first", timelineID: busyTimeline, clientTurnID: "parallel-first"),
                ascendantID: UUID()
            ) {
                await probe.enter("first")
                // Hold this Timeline until the independent Timeline has entered
                // instead of relying on scheduler timing.
                await probe.waitForStarts(2)
                await probe.leave()
                return "first"
            }
        }
        await probe.waitForStarts(1)
        let other = Task {
            try await coordinator.execute(
                TurnRequest(message: "other", timelineID: UUID(), clientTurnID: "parallel-other"),
                ascendantID: UUID()
            ) {
                await probe.enter("other")
                await probe.leave()
                return "other"
            }
        }
        _ = try await (first.value, other.value)
        #expect(await probe.maxActive == 2)
    }

    @Test("a rejected busy Turn leaves no Timeline slot behind and shutdown still settles the active Turn")
    func shutdownSettlesTheActiveTurnAfterABusyRejection() async throws {
        let coordinator = AscendantTurnCoordinator()
        let gate = BusyGate()
        let probe = BusyProbe()
        let timelineID = UUID()
        let active = Task {
            try await coordinator.execute(
                TurnRequest(message: "first", timelineID: timelineID, clientTurnID: "shutdown-first"),
                ascendantID: UUID()
            ) {
                await probe.enter("first")
                await gate.wait()
                try Task.checkCancellation()
                return "first"
            }
        }
        await probe.waitForStarts(1)
        let rejected = await BusyOutcome.settle {
            try await coordinator.execute(
                TurnRequest(message: "second", timelineID: timelineID, clientTurnID: "shutdown-second"),
                ascendantID: UUID()
            ) {
                await probe.enter("second")
                return "second"
            }
        }
        #expect(await coordinator.inFlightCount == 1)

        let shutdown = Task { await coordinator.cancelAll(waitForCompletion: true) }
        try await Task.sleep(for: .milliseconds(30))
        await gate.release()
        await shutdown.value
        _ = try? await active.value

        guard case .failure? = rejected else {
            Issue.record("The distinct Turn was queued instead of rejected: \(String(describing: rejected)).")
            return
        }
        #expect(await coordinator.inFlightCount == 0)
        #expect(await coordinator.retainedTimelineCount == 0)
        #expect(await probe.order == ["first"])
    }

    @Test("a busy rejection is not journaled as an admission")
    func busyRejectionIsNotJournaled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-busy-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let journals = TimelineJournalStore(directoryURL: directory)
        let ledger = AscendantTurnUpdateStore(timelineJournals: journals)
        let coordinator = AscendantTurnCoordinator(ledger: ledger)
        let gate = BusyGate()
        let probe = BusyProbe()
        let timelineID = UUID()
        let active = Task {
            try await coordinator.execute(
                TurnRequest(message: "first", timelineID: timelineID, clientTurnID: "journal-first"),
                ascendantID: UUID()
            ) {
                await probe.enter("first")
                await gate.wait()
                return "first"
            }
        }
        await probe.waitForStarts(1)
        let rejected = await BusyOutcome.settle {
            try await coordinator.execute(
                TurnRequest(message: "second", timelineID: timelineID, clientTurnID: "journal-second"),
                ascendantID: UUID()
            ) {
                await probe.enter("second")
                return "second"
            }
        }
        await gate.release()
        _ = try await active.value

        guard case .failure? = rejected else {
            Issue.record("The distinct Turn was queued instead of rejected: \(String(describing: rejected)).")
            return
        }
        let records = try await journals.journal(for: timelineID).replay()
        let admitted = records.compactMap { record -> String? in
            if case let .turnAdmitted(clientTurnID, _, _, _, _) = record.payload { return clientTurnID }
            return nil
        }
        #expect(admitted == ["journal-first"])
    }
}

/// The outcome of a call that may never settle if the contract regresses.
private enum BusyOutcome {
    /// Runs `operation` and returns its result, or `nil` when it has not
    /// settled within two seconds (for example because it is queued).
    static func settle<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error>? {
        let box = BusyResultBox<T>()
        let task = Task {
            do { await box.set(.success(try await operation())) } catch { await box.set(.failure(error)) }
        }
        for _ in 0..<200 {
            if let result = await box.value { return result }
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = task
        return await box.value
    }
}

private actor BusyResultBox<T: Sendable> {
    private(set) var value: Result<T, any Error>?

    func set(_ result: Result<T, any Error>) { value = result }
}

private actor BusyProbe {
    private(set) var order: [String] = []
    private(set) var active = 0
    private(set) var maxActive = 0

    var starts: Int { order.count }

    func enter(_ label: String) {
        order.append(label)
        active += 1
        maxActive = max(maxActive, active)
    }

    func leave() { active -= 1 }

    func waitForStarts(_ expected: Int) async {
        for _ in 0..<200 {
            if starts >= expected { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor BusyGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
