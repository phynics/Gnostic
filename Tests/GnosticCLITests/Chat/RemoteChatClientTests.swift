// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared
import Testing

@testable import GnosticCLI

@Suite("Remote chat client over the broker")
struct RemoteChatClientTests {
    @Test("chat, timeline status, and workspace ops resolve against a live serve") @MainActor
    func roundTripWithLiveServe() async throws {
        let namespace = "remote-chat-tests"
        let serve = try await serveRuntime(namespace: namespace, approveMode: .auto)
        defer { serve.shutdown() }
        try await serve.start()
        await serve.advertise(agent: AgentInstance(name: "serve", description: "test", privateTimelineID: serve.servedTimelineID), workspaces: [])

        let client = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()

        // Discover the served timeline from the advertised Agent.
        let timelineID = try await client.discoverServedTimeline()
        #expect(timelineID == serve.servedTimelineID)

        // Chat turn over agent.chat. The serve runs with an unconfigured LLM, so
        // the round-trip returns the serve's structured failure — proving the
        // Axoloty Call/Return path reached the served handler.
        await #expect(throws: RemoteCallFailure.self) {
            _ = try await client.chat(message: "hello", timelineID: timelineID)
        }

        // Timeline status.
        let status = try await client.timelineStatus(timelineID: timelineID)
        #expect(status.timelineID == timelineID)
        #expect(status.attachedWorkspaceIDs.isEmpty)
    }

    /// Workspace attach/detach over the served ops is covered by the contract
    /// tests in GnosticCore (WorkspaceOpsProvider) and wired end to end here once
    /// the serve-side workspace store import is unblocked (see #58 blocker).

    private func serveRuntime(namespace: String, approveMode: ServeApproveMode) async throws -> ServeRuntime {
        try await ServeRuntime(host: "127.0.0.1", port: 1883, namespace: namespace, approveMode: approveMode)
    }
}