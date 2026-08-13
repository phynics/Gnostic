// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// A thread-safe holder for the session's active timeline id.
private final class ActiveTimelineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID
    init(_ value: UUID) { self.value = value }

    var current: UUID {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func replace(with id: UUID) {
        lock.lock(); defer { lock.unlock() }
        value = id
    }
}

/// The remote (Axoloty) chat session used by `gnostic chat` against `gnostic
/// serve`. Satisfies `ChatTurnRunning` so the REPL is transport-agnostic.
///
/// The active timeline is owned by the chat session and can be switched via
/// `switchTimeline(to:)`, so turns and workspace operations target whichever
/// timeline the user has selected.
public final class RemoteChatSession: Sendable, ChatTurnRunning {
    private let client: RemoteChatClient
    private let activeTimeline: ActiveTimelineBox
    private let ascendantID: UUID?
    private let providerID: String?

    public init(client: RemoteChatClient, timelineID: UUID, ascendantID: UUID? = nil, providerID: String? = nil) {
        self.client = client
        self.activeTimeline = ActiveTimelineBox(timelineID)
        self.ascendantID = ascendantID
        self.providerID = providerID
    }

    /// The id of the currently active timeline.
    public var timelineID: UUID { activeTimeline.current }

    /// Switches the session to a different timeline.
    public func switchTimeline(to id: UUID) {
        activeTimeline.replace(with: id)
    }

    /// Creates a new timeline, activates it, and returns its status.
    @discardableResult
    public func createActivateTimeline(title: String) async throws -> TimelineStatus {
        let status = try await client.createTimeline(
            title: title,
            ascendantID: ascendantID,
            providerID: try await selectedProviderID()
        )
        switchTimeline(to: status.timelineID)
        return status
    }

    /// Renames the active timeline.
    @discardableResult
    public func renameActiveTimeline(title: String) async throws -> TimelineStatus {
        try await client.updateTimeline(timelineID: timelineID, title: title, providerID: try await selectedProviderID())
    }

    /// Lists every timeline the serve manages.
    public func listTimelines() async throws -> [TimelineStatus] {
        try await client.listTimelines(providerID: try await selectedProviderID())
    }

    /// One turn over the `agent.chat` unary. The serve may fail the turn (e.g.
    /// unconfigured LLM); that surfaces as a `.failed` result so the REPL stays
    /// alive.
    public func run(line: String) async throws -> ChatTurnResult {
        do {
            let text = try await client.chat(message: line, timelineID: timelineID, clientTurnID: nil, providerID: try await selectedProviderID())
            return .text(text.text)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - Workspace presentation + mutation (via served ops)

    /// The workspaces currently attached to the active timeline.
    public func attachedWorkspaceIDs() async throws -> [UUID] {
        let status = try await client.timelineStatus(timelineID: timelineID, providerID: try await selectedProviderID())
        return status.attachedWorkspaceIDs
    }

    /// The workspaces the serve can attach.
    public func attachableWorkspaces() async throws -> [WorkspaceListing] {
        try await client.listWorkspaces(providerID: try await selectedProviderID())
    }

    /// Attaches a workspace to the active timeline; `false` when denied.
    public func attach(_ workspaceID: UUID) async throws -> Bool {
        try await client.attach(workspaceID: workspaceID, timelineID: timelineID, providerID: try await selectedProviderID())
    }

    /// Detaches a workspace from the active timeline; `false` when denied.
    public func detach(_ workspaceID: UUID) async throws -> Bool {
        try await client.detach(workspaceID: workspaceID, timelineID: timelineID, providerID: try await selectedProviderID())
    }

    private func selectedProviderID() async throws -> String {
        if let providerID { return providerID }
        return try await client.selectAscendant(id: ascendantID).providerID
    }
}
