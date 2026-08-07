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
            AgentChatResult(text: "echo: \(request.message)")
        }
        let response = try await provider.handle(parameters: payload(AgentChatRequest(message: "hello over mqtt", timelineID: UUID())))
        let result = try JSONDecoder().decode(AgentChatResult.self, from: Data(try resultText(response).utf8))
        #expect(result.text == "echo: hello over mqtt")
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
}

/// Records attach/detach calls across the Sendable closures.
private actor AttachRecorder {
    private(set) var attached: [UUID] = []
    func record(_ id: UUID) { attached.append(id) }
    func remove(_ id: UUID) { attached.removeAll { $0 == id } }
}