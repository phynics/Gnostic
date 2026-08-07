// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared
import Testing

@Suite("Serve runtime over the broker")
struct ServeRuntimeTests {
    @Test("serve advertises its timeline and hosts the network operations") @MainActor
    func serveAdvertisesAndHostsOps() async throws {
        let namespace = "serve-runtime-tests"
        let runtime = try await ServeRuntime(host: "127.0.0.1", port: 1883, namespace: namespace, approveMode: .auto)
        defer { runtime.shutdown() }
        try await runtime.start()

        // Advertise the served objects.
        let agent = AgentInstance(name: "serve-tests", description: "test", privateTimelineID: runtime.servedTimelineID)
        await runtime.advertise(agent: agent, workspaces: [])

        // A consumer observes the timeline advertisement.
        let consumer = try ServeTestBroker.consumer(namespace: namespace)
        defer { consumer.stop() }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }

        let timelineID = runtime.servedTimelineID
        // Start the consumer and observe its state, then subscribe.
        try consumer.start()
        try await poll {
            let entries = await catalog.networkObjects()
            return entries.contains { $0.objectID == timelineID }
        }

        // The timeline.status operation resolves through the unary Call/Return.
        let request = TimelineStatusRequest(timelineID: timelineID)
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = try await consumer.call(
            operation: TimelineStatusProvider.statusOperation,
            parameters: payload,
            timeout: .seconds(3)
        )
        let status = try JSONDecoder().decode(
            TimelineStatus.self,
            from: Data(response.result.utf8)
        )
        #expect(status.timelineID == timelineID)
    }

    /// Polls a condition up to a bounded deadline.
    private func poll(what: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<50 {
            if await what() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }
}

/// A broker consumer helper for serve tests.
@MainActor
enum ServeTestBroker {
    static func consumer(namespace: String) throws -> CommunicationManager {
        try CommunicationManager(
            identity: Identity(name: "serve-tests-consumer"),
            communicationOptions: .init(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: .init(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
    }
}