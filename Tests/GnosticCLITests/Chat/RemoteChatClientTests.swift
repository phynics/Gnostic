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

    @Test("attach and detach a workspace over the served ops") @MainActor
    func attachDetachOverBroker() async throws {
        let namespace = "remote-chat-attach-tests"
        let serve = try await serveRuntime(namespace: namespace, approveMode: .auto)
        defer { serve.shutdown() }
        try await serve.start()
        let workspace = WorkspaceReference(
            id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!,
            uri: WorkspaceURI(parsing: "workspace://serve")!,
            location: .runtime,
            tools: [.custom(.init(id: "workspace_echo", name: "Workspace echo", description: "Echoes fixture input."))],
            createdAt: Date()
        )
        await serve.advertise(
            agent: AgentInstance(name: "serve", description: "test", privateTimelineID: serve.servedTimelineID),
            workspaces: [workspace]
        )

        let client = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()

        let timelineID = try await client.discoverServedTimeline()

        // The fixture workspace is listed as attachable.
        try await poll(timeout: .seconds(8)) {
            let list = try await client.listWorkspaces()
            return list.contains { $0.id == workspace.id }
        }

        // Attach, then the served timeline status reflects it.
        let attached = try await client.attach(workspaceID: workspace.id, timelineID: timelineID)
        #expect(attached)
        try await poll(timeout: .seconds(8)) {
            let status = try await client.timelineStatus(timelineID: timelineID)
            return status.attachedWorkspaceIDs.contains(workspace.id)
        }

        // Detach, then it's gone.
        let detached = try await client.detach(workspaceID: workspace.id, timelineID: timelineID)
        #expect(detached)
        try await poll(timeout: .seconds(8)) {
            let status = try await client.timelineStatus(timelineID: timelineID)
            return !status.attachedWorkspaceIDs.contains(workspace.id)
        }
    }

    @Test("timeline create/list/rename resolve over the broker") @MainActor
    func timelineManagementOverBroker() async throws {
        let namespace = "remote-chat-timeline-tests"
        let serve = try await serveRuntime(namespace: namespace, approveMode: .auto)
        defer { serve.shutdown() }
        try await serve.start()
        await serve.advertise(agent: AgentInstance(name: "serve", description: "test", privateTimelineID: serve.servedTimelineID), workspaces: [])

        let client = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()

        // The serve already created a default timeline at startup; list it.
        let initial = try await client.listTimelines()
        #expect(initial.contains { $0.timelineID == serve.servedTimelineID })

        // Create + activate a second timeline via the session.
        let session = RemoteChatSession(client: client, timelineID: serve.servedTimelineID)
        try await session.createActivateTimeline(title: "Research")
        #expect(session.timelineID != serve.servedTimelineID)

        // Rename the active timeline.
        let renamed = try await session.renameActiveTimeline(title: "Renamed Topic")
        #expect(renamed.title == "Renamed Topic")
        #expect(renamed.timelineID == session.timelineID)

        // Both timelines are now listed.
        let after = try await client.listTimelines()
        #expect(after.count == initial.count + 1)
        #expect(after.contains { $0.timelineID == session.timelineID && $0.title == "Renamed Topic" })

        // Switching back to the first timeline targets it.
        session.switchTimeline(to: serve.servedTimelineID)
        #expect(session.timelineID == serve.servedTimelineID)
    }

    @Test("workspace invocation keeps duplicate Timeline IDs scoped to the Workspace provider") @MainActor
    func workspaceInvocationScopesDuplicateTimelineIDs() async throws {
        let namespace = "remote-chat-duplicate-timeline-provider-tests"
        let timelineID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000011")!
        let firstWorkspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000012")!
        let secondWorkspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000013")!
        let firstAscendantID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000014")!
        let secondAscendantID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000015")!
        let firstManifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000016")!),
            ascendants: [.init(id: firstAscendantID, name: "First", defaultTimelineID: timelineID)],
            timelines: [.init(
                id: timelineID,
                title: "First duplicate",
                operatingAscendantID: firstAscendantID,
                attachments: [.local(firstWorkspaceID)]
            )],
            workspaces: [.init(id: firstWorkspaceID, name: "First echo", uri: "echo://first")]
        )
        let secondManifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000017")!),
            ascendants: [.init(id: secondAscendantID, name: "Second", defaultTimelineID: timelineID)],
            timelines: [.init(
                id: timelineID,
                title: "Second duplicate",
                operatingAscendantID: secondAscendantID,
                attachments: [.local(secondWorkspaceID)]
            )],
            workspaces: [.init(id: secondWorkspaceID, name: "Second echo", uri: "echo://second")]
        )
        let first = try await NodeRuntime(plan: firstManifest.compileLaunchPlan())
        let second = try await NodeRuntime(plan: secondManifest.compileLaunchPlan())
        try await first.start()
        try await second.start()
        defer {
            Task { @MainActor in
                await first.shutdown()
                await second.shutdown()
            }
        }

        let client = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()
        try await poll(timeout: .seconds(8)) {
            await client.discoverAscendants().count == 2
        }
        let providerID = try #require(
            await client.discoverAscendants().first { $0.id == secondAscendantID }?.providerID
        )

        let result = try await client.invokeWorkspace(
            workspaceID: secondWorkspaceID,
            providerID: providerID,
            timelineID: timelineID,
            toolID: "workspace_echo",
            parameters: ["value": AnyCodable("second-node")],
            approved: true
        )

        #expect(result.output == "second-node")
    }

    private func poll(
        timeout: Duration,
        _ condition: @escaping @Sendable () async throws -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("poll condition not met before \(timeout) timeout")
    }

    private func serveRuntime(namespace: String, approveMode: ServeApproveMode) async throws -> ServeRuntime {
        try await ServeRuntime(host: "127.0.0.1", port: 1883, namespace: namespace, approveMode: approveMode)
    }
}
