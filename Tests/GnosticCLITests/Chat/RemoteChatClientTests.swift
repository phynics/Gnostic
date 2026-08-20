// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared
import Testing

@testable import GnosticCLI

@Suite("Remote chat client over the broker")
struct RemoteTurnClientTests {
    @Test("chat, timeline status, and workspace ops resolve against a live serve") @MainActor
    func roundTripWithLiveServe() async throws {
        let namespace = "remote-chat-tests"
        let node = try await nodeRuntime(namespace: namespace)
        defer { Task { await node.runtime.shutdown() } }
        try await node.runtime.start()

        let client = try RemoteTurnClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()
        try await poll(timeout: .seconds(8)) {
            await client.discoverAscendants().contains { $0.id == node.ascendantID }
        }
        let providerID = try await client.selectAscendant(id: node.ascendantID).providerID

        // Discover the served timeline from the advertised Agent.
        let timelineID = try await client.discoverServedTimeline()
        #expect(timelineID == node.timelineID)

        // Chat turn over ascendant.turn. The serve runs with an unconfigured LLM, so
        // the round-trip returns the serve's structured failure — proving the
        // Axoloty Call/Return path reached the served handler.
        await #expect(throws: RemoteCallFailure.self) {
            _ = try await client.turn(message: "hello", timelineID: timelineID, clientTurnID: nil, providerID: providerID)
        }

        // Timeline status.
        let status = try await client.timelineStatus(timelineID: timelineID, providerID: providerID)
        #expect(status.timelineID == timelineID)
        #expect(status.attachedWorkspaceIDs.isEmpty)
    }

    @Test("attach and detach a workspace over the served ops") @MainActor
    func attachDetachOverBroker() async throws {
        let namespace = "remote-chat-attach-tests"
        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let node = try await nodeRuntime(
            namespace: namespace,
            workspaces: [.init(id: workspaceID, name: "Echo fixture", uri: "echo://serve")]
        )
        defer { Task { await node.runtime.shutdown() } }
        try await node.runtime.start()

        let client = try RemoteTurnClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()
        try await poll(timeout: .seconds(8)) {
            await client.discoverAscendants().contains { $0.id == node.ascendantID }
        }
        let providerID = try await client.selectAscendant(id: node.ascendantID).providerID
        let timelineID = node.timelineID

        // The fixture workspace is listed as attachable.
        try await poll(timeout: .seconds(8)) {
            let list = try await client.listWorkspaces(providerID: providerID)
            return list.contains { $0.id == workspaceID }
        }

        // Attach, then the served timeline status reflects it.
        let attached = try await client.attach(workspaceID: workspaceID, timelineID: timelineID, providerID: providerID)
        #expect(attached)
        try await poll(timeout: .seconds(8)) {
            let status = try await client.timelineStatus(timelineID: timelineID, providerID: providerID)
            return status.attachedWorkspaceIDs.contains(workspaceID)
        }

        // Detach, then it's gone.
        let detached = try await client.detach(workspaceID: workspaceID, timelineID: timelineID, providerID: providerID)
        #expect(detached)
        try await poll(timeout: .seconds(8)) {
            let status = try await client.timelineStatus(timelineID: timelineID, providerID: providerID)
            return !status.attachedWorkspaceIDs.contains(workspaceID)
        }
    }

    @Test("timeline create/list/rename resolve over the broker") @MainActor
    func timelineManagementOverBroker() async throws {
        let namespace = "remote-chat-timeline-tests"
        let node = try await nodeRuntime(namespace: namespace)
        defer { Task { await node.runtime.shutdown() } }
        try await node.runtime.start()

        let client = try RemoteTurnClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()
        try await poll(timeout: .seconds(8)) {
            await client.discoverAscendants().contains { $0.id == node.ascendantID }
        }
        let providerID = try await client.selectAscendant(id: node.ascendantID).providerID

        // The Node already created a default timeline at startup; list it.
        let initial = try await client.listTimelines(providerID: providerID)
        #expect(initial.contains { $0.timelineID == node.timelineID })

        // Create + activate a second timeline via the session.
        let session = RemoteTurnSession(
            client: client,
            timelineID: node.timelineID,
            ascendantID: node.ascendantID,
            providerID: providerID
        )
        try await session.createActivateTimeline(title: "Research")
        #expect(session.timelineID != node.timelineID)

        // Rename the active timeline.
        let renamed = try await session.renameActiveTimeline(title: "Renamed Topic")
        #expect(renamed.title == "Renamed Topic")
        #expect(renamed.timelineID == session.timelineID)

        // Both timelines are now listed.
        let after = try await client.listTimelines(providerID: providerID)
        #expect(after.count == initial.count + 1)
        #expect(after.contains { $0.timelineID == session.timelineID && $0.title == "Renamed Topic" })

        // Switching back to the first timeline targets it.
        session.switchTimeline(to: node.timelineID)
        #expect(session.timelineID == node.timelineID)
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

        let client = try RemoteTurnClient(host: "127.0.0.1", port: 1883, namespace: namespace)
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

    private func nodeRuntime(
        namespace: String,
        workspaces: [NodeManifest.Workspace] = []
    ) async throws -> (runtime: NodeRuntime, ascendantID: UUID, timelineID: UUID) {
        let ascendantID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000002")!
        let timelineID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000003")!
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000004")!),
            ascendants: [.init(id: ascendantID, name: "Test Ascendant", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Test Timeline", operatingAscendantID: ascendantID)],
            workspaces: workspaces
        )
        return (try await NodeRuntime(plan: manifest.compileLaunchPlan()), ascendantID, timelineID)
    }
}
