// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import Testing

@testable import GnosticRunner

@Suite("Online runner runtime")
struct OnlineRunnerTests {
    @Test("online runtime starts and shuts down") @MainActor
    func onlineRuntimeStartsAndServes() async throws {
        let name = "online-runner-\(UUID().uuidString.prefix(8).lowercased())"
        let ascendantID = UUID()
        let timelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: name),
            node: .init(id: UUID()),
            ascendants: [.init(
                id: ascendantID,
                name: "Letta",
                defaultTimelineID: timelineID,
                backend: .init(kind: "letta", settings: [
                    "serverURL": .string("http://127.0.0.1:8283"),
                    "model": .string("openai/test-model"),
                ])
            )],
            timelines: [.init(id: timelineID, title: "Letta", operatingAscendantID: ascendantID)],
            workspaces: []
        )
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("online-runner-state", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = try await RunnerRuntime(
            plan: manifest.compileLaunchPlan(),
            timelineJournalDirectory: stateDirectory
        )
        try await runtime.start()
        let snapshot = await runtime.runtime.snapshot()
        #expect(snapshot.ascendantIDs == [ascendantID])
        await runtime.shutdown()
    }

    @Test("online runtime hosts a non-Positronic Letta backend") @MainActor
    func onlineRuntimeHostsNonPositronicBackend() async throws {
        let name = "online-runner-letta-\(UUID().uuidString.prefix(8).lowercased())"
        let ascendantID = UUID()
        let timelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: name),
            node: .init(id: UUID()),
            ascendants: [.init(
                id: ascendantID,
                name: "Letta",
                defaultTimelineID: timelineID,
                backend: .init(kind: "letta", settings: [
                    "serverURL": .string("http://127.0.0.1:8283"),
                    "model": .string("openai/test-model"),
                ])
            )],
            timelines: [.init(id: timelineID, title: "Letta", operatingAscendantID: ascendantID)]
        )

        // The Letta kind is registered only in GnosticHost's composition. The
        // runner accepts this manifest because it composes through it.
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("online-runner-letta-state", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = try await RunnerRuntime(
            plan: manifest.compileLaunchPlan(),
            timelineJournalDirectory: stateDirectory
        )
        do {
            try await runtime.start()
            let snapshot = await runtime.runtime.snapshot()
            #expect(snapshot.ascendantIDs == [ascendantID])
            #expect(snapshot.timelineIDs == [timelineID])
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }
}

/// A broker consumer used to observe advertisements from the online runtime.
@MainActor
final class OnlineRunnerConsumer {
    private let manager: CommunicationManager

    init(namespace: String) throws {
        manager = try CommunicationManager(
            identity: Identity(name: "online-runner-consumer"),
            communicationOptions: .init(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: .init(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
    }

    func stop() { manager.stop() }

    /// Subscribes, runs `advertise`, and returns the object ids observed on the
    /// advertise stream.
    func observeAdvertised(_ advertise: () async throws -> Void) async throws -> [String] {
        let stream = try await manager.observeAdvertiseStream(withObjectType: GnosticObjectType.workspace)
        let task = Task { () -> [String] in
            var ids: [String] = []
            for await event in stream {
                ids.append(event.object.objectId)
            }
            return ids
        }
        try manager.start()
        try? await Task.sleep(for: .milliseconds(300)) // let subscription settle
        try await advertise()
        try? await Task.sleep(for: .milliseconds(1_000)) // let advertisements arrive
        manager.stop()
        task.cancel()
        return await task.value
    }
}
