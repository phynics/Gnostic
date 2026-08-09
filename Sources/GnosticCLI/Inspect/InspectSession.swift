// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore

/// Bounded broker observation: connect, subscribe to canonical Gnostic types,
/// collect a deterministic snapshot within a deadline, then disconnect.
@MainActor
final class InspectSession {
    private let values: InspectConnectionValues

    init(values: InspectConnectionValues) {
        self.values = values
    }

    func collect() async throws -> [NetworkCatalogEntry] {
        let store = CLIConfigurationStore()
        let stored = try store.load()

        let host = values.host ?? stored.mqttHost
        let port = values.port ?? stored.mqttPort
        let namespace = values.namespace ?? stored.mqttNamespace

        let manager = try CommunicationManager(
            identity: Identity(name: "gnostic-inspect"),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: host,
                    port: UInt16(clamping: port),
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )

        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: manager)

        do {
            try await start(manager)
            try await subscription.start()
            await subscription.discover(using: manager, timeout: .seconds(values.observeSeconds))
            let entries = await catalog.networkObjects()
            subscription.stop()
            manager.stop()
            return entries
        } catch let error as InspectError {
            subscription.stop()
            manager.stop()
            throw error
        } catch {
            subscription.stop()
            manager.stop()
            if error is CancellationError {
                throw InspectError.brokerUnreachable("timed out")
            }
            throw InspectError.connectionFailed(String(describing: error))
        }
    }

    /// Starts the manager and waits for the connection to come online within a
    /// bounded window, failing fast with a structured error when the broker is
    /// unreachable.
    private func start(_ manager: CommunicationManager) async throws {
        try manager.start()

        // Observe the connection lifecycle in a child task, racing it against a
        // deadline. Cancelling the observer after the deadline surfaces its
        // latest result deterministically without a task group (region-isolation
        // friendly).
        let observer = Task { @MainActor () async -> Bool in
            let stream = await manager.observeCommunicationStateStream()
            for await state in stream where state == .online {
                return true
            }
            return false
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(values.observeSeconds))
        }
        await deadline.value
        observer.cancel()
        let online = await observer.value
        await deadline.value

        guard online else {
            throw InspectError.brokerUnreachable("timed out connecting")
        }
    }

}
