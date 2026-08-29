// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Ascendant permission coordination")
struct AscendantPermissionCoordinatorTests {
    @Test("a correlated permission response is single-use and replayable")
    func correlatedResponse() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let timelineID = UUID()
        let request = AscendantPermissionRequest(
            correlationID: "permission-1",
            timelineID: timelineID,
            clientTurnID: "turn-1",
            toolCallID: "call-1",
            title: "Write file"
        )

        let decision = Task { await coordinator.request(request) }
        try await waitUntil {
            await updates.replay(timelineID: timelineID, clientTurnID: "turn-1").updates
                .contains { $0.permissionState?.status == "pending" }
        }

        #expect(await coordinator.respond(
            correlationID: "permission-1",
            timelineID: timelineID,
            clientTurnID: "turn-1",
            approved: true
        ))
        #expect(await decision.value)
        #expect(!(await coordinator.respond(
            correlationID: "permission-1",
            timelineID: timelineID,
            clientTurnID: "turn-1",
            approved: true
        )))

        let replay = await updates.replay(timelineID: timelineID, clientTurnID: "turn-1")
        #expect(replay.updates.compactMap(\.permissionState?.status) == ["pending", "selected"])
    }

    @Test("connection loss denies every pending permission")
    func connectionLossDenies() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let timelineID = UUID()
        let request = AscendantPermissionRequest(
            correlationID: "permission-loss",
            timelineID: timelineID,
            clientTurnID: "turn-loss",
            toolCallID: "call-loss",
            title: "Delete file"
        )

        let decision = Task { await coordinator.request(request) }
        try await waitUntil { await coordinator.pendingCount == 1 }
        await coordinator.denyAll(reason: "connection_lost")

        #expect(!(await decision.value))
        let replay = await updates.replay(timelineID: timelineID, clientTurnID: "turn-loss")
        #expect(replay.updates.last?.permissionState?.status == "connection_lost")
    }

    @Test("responses after connection loss cannot reopen a permission")
    func lateResponseAfterConnectionLossIsRejected() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let timelineID = UUID()
        let request = AscendantPermissionRequest(
            correlationID: "permission-late",
            timelineID: timelineID,
            clientTurnID: "turn-late",
            toolCallID: "call-late",
            title: "Delete file"
        )

        let decision = Task { await coordinator.request(request) }
        try await waitUntil { await coordinator.pendingCount == 1 }
        await coordinator.denyAll(reason: "connection_lost")

        #expect(!(await coordinator.request(request)))
        #expect(!(await coordinator.respond(
            correlationID: request.correlationID,
            timelineID: timelineID,
            clientTurnID: request.clientTurnID,
            approved: true
        )))
        #expect(!(await decision.value))
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was not satisfied")
    }
}
