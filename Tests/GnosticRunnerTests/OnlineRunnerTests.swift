// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts
import Testing

@testable import GnosticRunner

@Suite("Online runner runtime")
struct OnlineRunnerTests {
    @Test("online runtime starts, serves an advertised object, and shuts down") @MainActor
    func onlineRuntimeStartsAndServes() async throws {
        let name = "online-runner-tests"
        let configuration = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: "127.0.0.1", port: 1883, namespace: name),
            environment: [:]
        )
        let runtime = try RunnerRuntime(configuration: configuration)
        defer { runtime.shutdown() }

        try await runtime.start()

        // The runtime's lifecycle controller should advertise a canonical object
        // that a consumer can observe over the broker.
        let consumer = try OnlineRunnerConsumer(namespace: name)
        defer { consumer.stop() }

        let workspaceID = UUID(uuidString: "E51D0000-0000-4000-8000-000000000001")!
        let workspace = GnosticWorkspaceObject(workspace: GnosticWorkspaceReference(
            id: workspaceID,
            uri: "workspace://online",
            tools: [.init(id: "echo", name: "Echo", description: "Echoes input.")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        // Advertise through the runtime's own lifecycle and observe from a
        // separate consumer on the same namespace.
        let observed = try await consumer.observeAdvertised {
            runtime.lifecycle.advertiseDiscoverableObject(object: workspace)
        }
        #expect(observed.contains(workspaceID.uuidString.lowercased()))
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

    /// Observes the advertise stream while `advertise` runs, returning observed object ids.
    func observeAdvertised(_ advertise: () -> Void) async throws -> [String] {
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
        advertise()
        try? await Task.sleep(for: .milliseconds(600)) // let the advertisement arrive
        manager.stop()
        task.cancel()
        return await task.value
    }
}
