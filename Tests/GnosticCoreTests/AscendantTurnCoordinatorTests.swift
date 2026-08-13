// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Ascendant turn coordination")
struct AscendantTurnCoordinatorTests {
    @Test("same id and content executes once and replays the result")
    func duplicateTurnReplays() async throws {
        let coordinator = AscendantTurnCoordinator()
        let probe = TurnProbe()
        let timelineID = UUID()
        let request = AgentChatRequest(
            message: "hello",
            timelineID: timelineID,
            clientTurnID: "pi:session:entry-1"
        )

        let first = try await coordinator.execute(request) {
            await probe.enter("first")
            await probe.leave()
            return "answer"
        }
        let replay = try await coordinator.execute(request) {
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
        let firstRequest = AgentChatRequest(message: "first", timelineID: timelineID, clientTurnID: "turn-1")
        let conflictRequest = AgentChatRequest(message: "different", timelineID: timelineID, clientTurnID: "turn-1")

        _ = try await coordinator.execute(firstRequest) {
            await probe.enter("first")
            await probe.leave()
            return "answer"
        }

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(conflictRequest) {
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
        let firstRequest = AgentChatRequest(message: "first", timelineID: timelineID, clientTurnID: "turn-1")
        let secondRequest = AgentChatRequest(message: "second", timelineID: timelineID, clientTurnID: "turn-2")
        let otherRequest = AgentChatRequest(message: "other", timelineID: UUID(), clientTurnID: "turn-3")

        let first = Task {
            try await coordinator.execute(firstRequest) {
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
            try await coordinator.execute(secondRequest) {
                await probe.enter("second")
                await probe.leave()
                return "second"
            }
        }
        let other = Task {
            try await coordinator.execute(otherRequest) {
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
        let firstRequest = AgentChatRequest(message: "first", timelineID: timelineID)
        let secondRequest = AgentChatRequest(message: "second", timelineID: timelineID)

        let first = Task {
            try await coordinator.execute(firstRequest) {
                await probe.enter("first")
                try await Task.sleep(for: .milliseconds(80))
                await probe.leave()
                return "first"
            }
        }
        await probe.waitForStarts(1)
        let second = Task {
            try await coordinator.execute(secondRequest) {
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
        let request = AgentChatRequest(message: "once", timelineID: UUID(), clientTurnID: "turn-cancelled")

        let caller = Task {
            try await coordinator.execute(request) {
                await probe.enter("original")
                try await Task.sleep(for: .milliseconds(100))
                await probe.leave()
                return "completed"
            }
        }
        await probe.waitForStarts(1)
        caller.cancel()

        let replay = try await coordinator.execute(request) {
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
        let failedRequest = AgentChatRequest(message: "fails", timelineID: UUID(), clientTurnID: "turn-fails")
        let cancelledRequest = AgentChatRequest(message: "cancels", timelineID: UUID(), clientTurnID: "turn-cancels")

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(failedRequest) {
                await probe.enter("failed")
                throw TestTurnError.failed
            }
        }
        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(failedRequest) {
                await probe.enter("failed-retry")
                return "must not run"
            }
        }

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(cancelledRequest) {
                await probe.enter("cancelled")
                throw CancellationError()
            }
        }
        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(cancelledRequest) {
                await probe.enter("cancelled-retry")
                return "must not run"
            }
        }

        #expect(await probe.starts == 2)
    }

    @Test("evicted results retain a non-retryable identity tombstone")
    func evictedResultsNeverRerun() async throws {
        let coordinator = AscendantTurnCoordinator(completedCapacity: 1)
        let probe = TurnProbe()
        let first = AgentChatRequest(message: "first", timelineID: UUID(), clientTurnID: "turn-1")
        let second = AgentChatRequest(message: "second", timelineID: UUID(), clientTurnID: "turn-2")

        _ = try await coordinator.execute(first) {
            await probe.enter("first")
            return "one"
        }
        _ = try await coordinator.execute(second) {
            await probe.enter("second")
            return "two"
        }

        await #expect(throws: AscendantTurnError.self) {
            _ = try await coordinator.execute(first) {
                await probe.enter("rerun")
                return "must not run"
            }
        }
        #expect(await probe.starts == 2)
    }
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
