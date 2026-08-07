// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// The remote (Axoloty) chat session used by `gnostic chat` against `gnostic
/// serve`. Satisfies `ChatTurnRunning` so the REPL is transport-agnostic.
public final class RemoteChatSession: Sendable, ChatTurnRunning {
    private let client: RemoteChatClient
    public let timelineID: UUID

    public init(client: RemoteChatClient, timelineID: UUID) {
        self.client = client
        self.timelineID = timelineID
    }

    /// One turn over the `agent.chat` unary. The serve may fail the turn (e.g.
    /// unconfigured LLM); that surfaces as a `.failed` result so the REPL stays
    /// alive.
    public func run(line: String) async throws -> ChatTurnResult {
        do {
            let text = try await client.chat(message: line, timelineID: timelineID)
            return .text(text)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - Workspace presentation + mutation (via served ops)

    /// The workspaces currently attached to the served timeline.
    public func attachedWorkspaceIDs() async throws -> [UUID] {
        let status = try await client.timelineStatus(timelineID: timelineID)
        return status.attachedWorkspaceIDs
    }

    /// The workspaces the serve can attach.
    public func attachableWorkspaces() async throws -> [WorkspaceListing] {
        try await client.listWorkspaces()
    }

    /// Attaches a workspace; `false` when the serve denied it.
    public func attach(_ workspaceID: UUID) async throws -> Bool {
        try await client.attach(workspaceID: workspaceID, timelineID: timelineID)
    }

    /// Detaches a workspace; `false` when the serve denied it.
    public func detach(_ workspaceID: UUID) async throws -> Bool {
        try await client.detach(workspaceID: workspaceID, timelineID: timelineID)
    }
}