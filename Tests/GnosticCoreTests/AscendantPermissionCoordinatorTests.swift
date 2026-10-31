// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Ascendant permission coordination")
struct AscendantPermissionCoordinatorTests {
    @Test("a host-side failure is not reported as a client denial")
    func hostFailureIsDistinctFromDenial() async throws {
        // One retention slot, already occupied, so the permission request
        // cannot be recorded and the client never sees a choice.
        let updates = AscendantTurnUpdateStore(maxEntries: 1)
        try await updates.start(timelineID: UUID(), clientTurnID: "occupying-turn")
        let coordinator = AscendantPermissionCoordinator(updates: updates)

        let unavailable = await coordinator.requestApproval(for: BackendPermissionRequest(
            correlationID: "permission-capacity",
            timelineID: UUID(),
            clientTurnID: "turn-capacity",
            toolCallID: "call-capacity",
            title: "Write file"
        ))

        // The client was never asked, so this must not read as a denial.
        #expect(unavailable != .denied)
        guard case let .unavailable(reason) = unavailable else {
            Issue.record("Expected an unavailable decision, got \(unavailable).")
            return
        }
        #expect(reason == "retentionCapacityExceeded")
        #expect(!unavailable.isApproved)
    }

    @Test("a request nobody answers resolves as unavailable within the bound, and a late answer is refused")
    func unansweredRequestIsBounded() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates, unansweredBound: .milliseconds(50))
        let timelineID = UUID()
        let request = BackendPermissionRequest(
            correlationID: "permission-unanswered",
            timelineID: timelineID,
            clientTurnID: "turn-unanswered",
            toolCallID: "call-unanswered",
            title: "Write file"
        )

        let decision = await coordinator.requestApproval(for: request)

        guard case let .unavailable(reason) = decision else {
            Issue.record("Expected an unavailable decision, got \(decision).")
            return
        }
        #expect(reason == "permissionUnanswered")
        #expect(await coordinator.pendingCount == 0)
        let lateAnswer = await coordinator.respond(
            correlationID: request.correlationID,
            timelineID: timelineID,
            clientTurnID: "turn-unanswered",
            approved: true
        )
        #expect(!lateAnswer)
    }

    @Test("an answer inside the bound wins and the bound does not fire afterwards")
    func answerInsideTheBound() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates, unansweredBound: .seconds(30))
        let timelineID = UUID()
        let request = BackendPermissionRequest(
            correlationID: "permission-answered",
            timelineID: timelineID,
            clientTurnID: "turn-answered",
            toolCallID: "call-answered",
            title: "Write file"
        )

        let decision = Task { await coordinator.requestApproval(for: request) }
        try await waitUntil { await coordinator.pendingCount == 1 }
        #expect(await coordinator.respond(
            correlationID: request.correlationID,
            timelineID: timelineID,
            clientTurnID: "turn-answered",
            approved: true
        ))
        #expect(await decision.value == .approved)
    }

    @Test("a cancelled caller clears its request, so its correlation ID can be used again")
    func cancelledCallerClearsPending() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates, unansweredBound: .seconds(30))
        let request = BackendPermissionRequest(
            correlationID: "permission-cancelled",
            timelineID: UUID(),
            clientTurnID: "turn-cancelled",
            toolCallID: "call-cancelled",
            title: "Write file"
        )

        let waiting = Task { await coordinator.requestApproval(for: request) }
        try await waitUntil { await coordinator.pendingCount == 1 }
        waiting.cancel()
        _ = await waiting.value
        try await waitUntil { await coordinator.pendingCount == 0 }
        #expect(await coordinator.pendingCount == 0)
    }

    @Test("a client that makes no decision settles the request at once as unavailable")
    func clientWithheldDecision() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates, unansweredBound: .seconds(30))
        let timelineID = UUID()
        let request = BackendPermissionRequest(
            correlationID: "permission-withheld",
            timelineID: timelineID,
            clientTurnID: "turn-withheld",
            toolCallID: "call-withheld",
            title: "Write file"
        )

        let decision = Task { await coordinator.requestApproval(for: request) }
        try await waitUntil { await coordinator.pendingCount == 1 }
        #expect(await coordinator.respond(
            correlationID: request.correlationID,
            timelineID: timelineID,
            clientTurnID: "turn-withheld",
            approved: false,
            unavailableReason: "clientCancelled"
        ))

        #expect(await decision.value == .unavailable(reason: "clientCancelled"))
    }

    @Test("an explicit client denial is reported as a denial")
    func explicitDenialIsADenial() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let timelineID = UUID()
        let request = BackendPermissionRequest(
            correlationID: "permission-deny",
            timelineID: timelineID,
            clientTurnID: "turn-deny",
            toolCallID: "call-deny",
            title: "Write file"
        )

        let decision = Task { await coordinator.requestApproval(for: request) }
        try await waitUntil {
            (try? await updates.replay(timelineID: timelineID, clientTurnID: "turn-deny").updates
                .contains { $0.permissionState?.status == "pending" }) ?? false
        }
        #expect(await coordinator.respond(
            correlationID: "permission-deny",
            timelineID: timelineID,
            clientTurnID: "turn-deny",
            approved: false
        ))

        #expect(await decision.value == .denied)
    }

    @Test("a correlated permission response is single-use and replayable")
    func correlatedResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journals = TimelineJournalStore(directoryURL: directory)
        let updates = AscendantTurnUpdateStore(timelineJournals: journals)
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let timelineID = UUID()
        let request = BackendPermissionRequest(
            correlationID: "permission-1",
            timelineID: timelineID,
            clientTurnID: "turn-1",
            toolCallID: "call-1",
            title: "Write file"
        )

        let decision = Task { await coordinator.requestApproval(for: request) }
        try await waitUntil {
            (try? await updates.replay(timelineID: timelineID, clientTurnID: "turn-1").updates
                .contains { $0.permissionState?.status == "pending" }) ?? false
        }

        #expect(await coordinator.respond(
            correlationID: "permission-1",
            timelineID: timelineID,
            clientTurnID: "turn-1",
            approved: true
        ))
        #expect(await decision.value == .approved)
        let journal = try await journals.journal(for: timelineID)
        #expect(try await journal.replay().contains { record in
            if case let .permissionDecision(correlationID, clientTurnID, decision, approved) = record.payload {
                return correlationID == "permission-1" && clientTurnID == "turn-1" && decision == "approved" && approved
            }
            return false
        })
        #expect(!(await coordinator.respond(
            correlationID: "permission-1",
            timelineID: timelineID,
            clientTurnID: "turn-1",
            approved: true
        )))

        let replay = try await updates.replay(timelineID: timelineID, clientTurnID: "turn-1")
        #expect(replay.updates.compactMap(\.permissionState?.status) == ["pending", "selected"])
    }

    @Test("invalid permission identity is rejected before pending admission")
    func invalidPermissionIdentityIsRejected() async {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let request = BackendPermissionRequest(
            correlationID: "invalid-permission",
            timelineID: UUID(),
            clientTurnID: "   ",
            toolCallID: "call-1",
            title: "Write file"
        )
        #expect(await coordinator.requestApproval(for: request) == .unavailable(reason: "invalidClientTurnID"))
        #expect(await coordinator.pendingCount == 0)
        #expect((await updates.retainedStateCounts).entries == 0)
    }

    @Test("connection loss withdraws every pending permission rather than denying it")
    func connectionLossWithdrawsPendingPermissions() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let timelineID = UUID()
        let request = BackendPermissionRequest(
            correlationID: "permission-loss",
            timelineID: timelineID,
            clientTurnID: "turn-loss",
            toolCallID: "call-loss",
            title: "Delete file"
        )

        let decision = Task { await coordinator.requestApproval(for: request) }
        try await waitUntil { await coordinator.pendingCount == 1 }
        await coordinator.denyAll(reason: .connectionLost)

        // The client was never asked, so this is a withdrawal, not a denial.
        #expect(await decision.value == .unavailable(reason: "connection_lost"))
        let replay = try await updates.replay(timelineID: timelineID, clientTurnID: "turn-loss")
        #expect(replay.updates.last?.permissionState?.status == "connection_lost")
    }

    @Test("responses after connection loss cannot reopen a permission")
    func lateResponseAfterConnectionLossIsRejected() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let timelineID = UUID()
        let request = BackendPermissionRequest(
            correlationID: "permission-late",
            timelineID: timelineID,
            clientTurnID: "turn-late",
            toolCallID: "call-late",
            title: "Delete file"
        )

        let decision = Task { await coordinator.requestApproval(for: request) }
        try await waitUntil { await coordinator.pendingCount == 1 }
        await coordinator.denyAll(reason: .connectionLost)

        #expect(await coordinator.requestApproval(for: request) == .unavailable(reason: "permissionMediationStopped"))
        #expect(!(await coordinator.respond(
            correlationID: request.correlationID,
            timelineID: timelineID,
            clientTurnID: request.clientTurnID,
            approved: true
        )))
        #expect(!(await decision.value.isApproved))
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was not satisfied")
    }
}
