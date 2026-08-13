// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import Testing

@Suite("Serve network operation contracts")
struct ServeOperationContractTests {
    // The providers are thin wire adapters: decode a JSON payload, invoke an
    // injected closure (the serve runtime's logic), and encode the result. These
    // tests pin the wire contract without a broker or an LLM.

    private func payload<T: Encodable>(_ value: T) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private func resultText(_ response: CallHandlerResult) throws -> String {
        guard case let .success(result: text, executionInfo: _) = response else {
            Issue.record("expected success result, got \(response)")
            return ""
        }
        return text
    }

    @Test("agent.chat decodes the request, runs the closure, and encodes the result")
    func agentChatContract() async throws {
        let provider = AgentChatProvider { request in
            AgentChatResult(clientTurnID: request.clientTurnID, text: "echo: \(request.message)")
        }
        let request = AgentChatRequest(message: "hello over mqtt", timelineID: UUID(), clientTurnID: "pi:entry-1")
        let response = try await provider.handle(parameters: payload(request))
        let result = try JSONDecoder().decode(AgentChatResult.self, from: Data(try resultText(response).utf8))
        #expect(result.text == "echo: hello over mqtt")
        #expect(result.clientTurnID == request.clientTurnID)
        #expect(!result.replayed)
    }

    @Test("agent.chat conflict is a structured failure")
    func agentChatConflictContract() async throws {
        let coordinator = AscendantTurnCoordinator()
        let provider = AgentChatProvider { request in
            try await coordinator.execute(request) { "echo: \(request.message)" }
        }
        let timelineID = UUID()
        let first = AgentChatRequest(message: "first", timelineID: timelineID, clientTurnID: "turn-1")
        let conflict = AgentChatRequest(message: "second", timelineID: timelineID, clientTurnID: "turn-1")

        _ = try await provider.handle(parameters: payload(first))
        let response = try await provider.handle(parameters: payload(conflict))
        guard case let .failure(code, message, _) = response else {
            Issue.record("expected a structured conflict failure")
            return
        }
        #expect(code == 409)
        #expect(message.contains("clientTurnID turn-1"))
    }

    @Test("agent.chat.replay returns bounded identified-turn updates")
    func agentChatReplayContract() async throws {
        let timelineID = UUID()
        let store = AscendantTurnUpdateStore()
        let provider = AgentChatProvider(
            execute: { request in
                AgentChatResult(clientTurnID: request.clientTurnID, text: "echo: \(request.message)")
            },
            replayStore: store
        )
        let request = AgentChatRequest(message: "hello", timelineID: timelineID, clientTurnID: "turn-replay")
        _ = try await provider.handle(parameters: payload(request))

        let replayRequest = AgentChatReplayRequest(timelineID: timelineID, clientTurnID: "turn-replay")
        let response = try await provider.handleReplay(parameters: payload(replayRequest))
        let replay = try JSONDecoder().decode(
            AscendantTurnReplay.self,
            from: Data(try resultText(response).utf8)
        )
        #expect(replay.updates.map(\.kind) == ["assistant_text", "completion"])
        #expect(replay.terminal)
        #expect(replay.updates.last?.text == "echo: hello")
    }

    @Test("agent.chat keeps streamed text without appending a duplicate final message")
    func agentChatStreamReplayContract() async throws {
        let timelineID = UUID()
        let store = AscendantTurnUpdateStore()
        let provider = AgentChatProvider(
            execute: { request in
                _ = await store.append(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID!,
                    kind: "assistant_text",
                    text: "hel"
                )
                _ = await store.append(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID!,
                    kind: "assistant_text",
                    text: "lo"
                )
                return AgentChatResult(clientTurnID: request.clientTurnID, text: "hello")
            },
            replayStore: store
        )
        _ = try await provider.handle(parameters: payload(
            AgentChatRequest(message: "hello", timelineID: timelineID, clientTurnID: "turn-stream")
        ))

        let replay = await store.replay(timelineID: timelineID, clientTurnID: "turn-stream")
        #expect(replay.updates.map(\.kind) == ["assistant_text", "assistant_text", "completion"])
        #expect(replay.updates.compactMap(\.text) == ["hel", "lo", "hello"])
    }

    @Test("agent.chat result decoder accepts the legacy text-only response")
    func agentChatLegacyResultDecodes() throws {
        let result = try JSONDecoder().decode(
            AgentChatResult.self,
            from: Data(#"{"text":"legacy"}"#.utf8)
        )
        #expect(result.text == "legacy")
        #expect(result.clientTurnID == nil)
        #expect(!result.replayed)
    }

    @Test("agent.chat rejects a malformed payload")
    func agentChatRejectsMalformed() async throws {
        let provider = AgentChatProvider { _ in AgentChatResult(text: "unused") }
        let response = try await provider.handle(parameters: "not-json")
        guard case .failure(let code, _, _) = response else {
            Issue.record("expected failure for malformed payload")
            return
        }
        #expect(code == 400)
    }

    @Test("agent.chat rejects a blank client turn id")
    func agentChatRejectsBlankTurnID() async throws {
        let provider = AgentChatProvider { _ in AgentChatResult(text: "unused") }
        let request = AgentChatRequest(message: "hello", timelineID: UUID(), clientTurnID: "  ")
        let response = try await provider.handle(parameters: payload(request))
        guard case let .failure(code, _, _) = response else {
            Issue.record("expected failure for a blank client turn id")
            return
        }
        #expect(code == 400)
    }

    @Test("agent permission responses reject stale or mismatched correlations")
    func permissionResponseContract() async throws {
        let updates = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: updates)
        let provider = AgentPermissionProvider(coordinator: coordinator)
        let timelineID = UUID()
        let request = AscendantPermissionRequest(
            correlationID: "permission-contract",
            timelineID: timelineID,
            clientTurnID: "turn-contract",
            toolCallID: "call-contract",
            title: "Write file"
        )
        let decision = Task { await coordinator.request(request) }
        for _ in 0..<100 {
            if await coordinator.pendingCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let accepted = try await provider.handle(parameters: payload(AgentPermissionResponse(
            correlationID: request.correlationID,
            timelineID: timelineID,
            clientTurnID: request.clientTurnID,
            approved: true
        )))
        guard case .success = accepted else {
            Issue.record("expected permission response acceptance")
            return
        }
        #expect(await decision.value)

        let duplicate = try await provider.handle(parameters: payload(AgentPermissionResponse(
            correlationID: request.correlationID,
            timelineID: timelineID,
            clientTurnID: request.clientTurnID,
            approved: true
        )))
        guard case let .failure(code, _, _) = duplicate else {
            Issue.record("expected stale permission response failure")
            return
        }
        #expect(code == 409)
    }

    @Test("timeline.status decodes the timeline id and returns the status")
    func timelineStatusContract() async throws {
        let timelineID = UUID()
        let provider = TimelineStatusProvider { request in
            TimelineStatus(timelineID: request.timelineID, title: "Serviced timeline", attachedWorkspaceIDs: [])
        }
        let response = try await provider.handle(parameters: payload(TimelineStatusRequest(timelineID: timelineID)))
        let status = try JSONDecoder().decode(TimelineStatus.self, from: Data(try resultText(response).utf8))
        #expect(status.title == "Serviced timeline")
        #expect(status.timelineID == timelineID)
    }

    @Test("workspace ops route to list, attach, and detach closures")
    func workspaceOpsContract() async throws {
        let workspaceID = UUID()
        let recorder = AttachRecorder()
        let provider = WorkspaceOpsProvider(
            list: { [WorkspaceListing(id: UUID(), name: "Atlas")] },
            attach: { request in await recorder.record(request.workspaceID); return true },
            detach: { request in await recorder.remove(request.workspaceID); return true }
        )

        let listResponse = try await provider.handle(operation: WorkspaceOpsProvider.listOperation, parameters: nil)
        let list = try JSONDecoder().decode(WorkspaceListResult.self, from: Data(try resultText(listResponse).utf8))
        #expect(list.workspaces.first?.name == "Atlas")

        let attachRequest = WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: UUID())
        let attachResponse = try await provider.handle(operation: WorkspaceOpsProvider.attachOperation, parameters: payload(attachRequest))
        #expect(try resultText(attachResponse) == "true")
        #expect(await recorder.attached == [workspaceID])

        let detachResponse = try await provider.handle(operation: WorkspaceOpsProvider.detachOperation, parameters: payload(attachRequest))
        #expect(try resultText(detachResponse) == "true")
        #expect(await recorder.attached.isEmpty)
    }

    @Test("workspace ops convert domain and unexpected errors to structured failures")
    func workspaceOpsFailureContract() async throws {
        struct InjectedFailure: Error {}
        let request = WorkspaceOpsRequest(workspaceID: UUID(), timelineID: UUID())
        let provider = WorkspaceOpsProvider(
            list: { throw InjectedFailure() },
            attach: { _ in throw DiscoveredWorkspaceAttachmentError.invalidURI },
            detach: { _ in throw NodeRuntimeError.notRunning }
        )

        guard case let .failure(listCode, listMessage, _) = try await provider.handle(
            operation: WorkspaceOpsProvider.listOperation,
            parameters: nil
        ) else {
            Issue.record("expected structured list failure")
            return
        }
        #expect(listCode == 500)
        #expect(listMessage.hasPrefix("workspaceOperationFailed:"))

        guard case let .failure(attachCode, attachMessage, _) = try await provider.handle(
            operation: WorkspaceOpsProvider.attachOperation,
            parameters: payload(request)
        ) else {
            Issue.record("expected structured attach failure")
            return
        }
        #expect(attachCode == 422)
        #expect(attachMessage.hasPrefix("invalidWorkspaceURI:"))

        guard case let .failure(detachCode, detachMessage, _) = try await provider.handle(
            operation: WorkspaceOpsProvider.detachOperation,
            parameters: payload(request)
        ) else {
            Issue.record("expected structured detach failure")
            return
        }
        #expect(detachCode == 503)
        #expect(detachMessage.hasPrefix("notRunning:"))
    }

    @Test("timeline create/list/update route to the injected closures")
    func timelineManagementContract() async throws {
        let createdID = UUID()
        let provider = TimelineManagementProvider(
            create: { title in TimelineStatus(timelineID: createdID, title: title, attachedWorkspaceIDs: []) },
            list: {
                [TimelineStatus(timelineID: createdID, title: "Existing", attachedWorkspaceIDs: [])]
            },
            update: { request in TimelineStatus(timelineID: request.timelineID, title: request.title, attachedWorkspaceIDs: []) }
        )

        // create
        let createResponse = try await provider.handle(operation: TimelineManagementProvider.createOperation, parameters: payload(TimelineCreateRequest(title: "Research")))
        let created = try JSONDecoder().decode(TimelineStatus.self, from: Data(try resultText(createResponse).utf8))
        #expect(created.title == "Research")
        #expect(created.timelineID == createdID)

        // list
        let listResponse = try await provider.handle(operation: TimelineManagementProvider.listOperation, parameters: nil)
        let list = try JSONDecoder().decode(TimelineListResult.self, from: Data(try resultText(listResponse).utf8))
        #expect(list.timelines.count == 1)
        #expect(list.timelines.first?.title == "Existing")

        // update (rename)
        let updateResponse = try await provider.handle(operation: TimelineManagementProvider.updateOperation, parameters: payload(TimelineUpdateRequest(timelineID: createdID, title: "Renamed")))
        let updated = try JSONDecoder().decode(TimelineStatus.self, from: Data(try resultText(updateResponse).utf8))
        #expect(updated.title == "Renamed")
        #expect(updated.timelineID == createdID)
    }

    @Test("timeline ops reject malformed payloads")
    func timelineManagementRejectsMalformed() async throws {
        let provider = TimelineManagementProvider(
            create: { _ in TimelineStatus(timelineID: UUID(), title: "x", attachedWorkspaceIDs: []) },
            list: { [] },
            update: { _ in TimelineStatus(timelineID: UUID(), title: "x", attachedWorkspaceIDs: []) }
        )
        let bad = try await provider.handle(operation: TimelineManagementProvider.createOperation, parameters: "not-json")
        guard case .failure(let code, _, _) = bad else {
            Issue.record("expected failure for malformed create payload")
            return
        }
        #expect(code == 400)
    }
}

/// Records attach/detach calls across the Sendable closures.
private actor AttachRecorder {
    private(set) var attached: [UUID] = []
    func record(_ id: UUID) { attached.append(id) }
    func remove(_ id: UUID) { attached.removeAll { $0 == id } }
}
