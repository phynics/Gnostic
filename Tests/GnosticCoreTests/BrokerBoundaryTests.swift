// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

/// Transport-boundary regression scenarios (GNO-PLAT-061, #453).
///
/// These fault a broker the test owns, so a broker outage is deterministic and
/// does not disturb the shared deterministic broker other tests use.
@Suite("Broker transport boundary", .timeLimit(.minutes(2)))
@MainActor
struct BrokerBoundaryTests {
    @Test("a broker outage fails Turns cleanly and a restarted node serves after reconnect")
    func brokerOutageIsBoundedAndRecoverable() async throws {
        guard let broker = PrivateMosquitto.make() else {
            // No mosquitto binary: the container gate provides it.
            return
        }
        defer { broker.stop() }

        let namespace = "broker-boundary-\(UUID().uuidString.lowercased())"
        let ascendantID = UUID()
        let timelineID = UUID()

        func makeRuntime() async throws -> NodeRuntime {
            let manifest = NodeManifest(
                broker: .init(host: "127.0.0.1", port: broker.port, namespace: namespace),
                node: .init(id: UUID()),
                ascendants: [.init(
                    id: ascendantID,
                    name: "Broker boundary",
                    defaultTimelineID: timelineID,
                    backend: .init(kind: AscendantAdapterRegistry.positronicKind)
                )],
                timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
            )
            let runtime = try await NodeRuntime(
                plan: manifest.compileLaunchPlan(),
                adapters: positronicHostConformanceFixture().makeAdapters()
            )
            try await runtime.start()
            return runtime
        }

        func makeSession() async throws -> GnosticConsumerSession {
            let session = try GnosticConsumerSession(
                broker: .init(host: "127.0.0.1", port: broker.port, namespace: namespace),
                identityName: "broker-boundary-\(UUID().uuidString.lowercased())",
                connectTimeout: .seconds(5),
                discoverTimeout: .seconds(5)
            )
            try await session.start()
            try await session.discover()
            return session
        }

        let runtime = try await makeRuntime()
        let session = try await makeSession()
        let client = try session.turnClient(timeout: .seconds(5))

        let first = try await client.run(
            message: "before outage",
            timelineID: timelineID,
            clientTurnID: "boundary-1"
        )
        #expect(!first.text.isEmpty)

        // The broker dies. A Turn must fail within the caller's bound, not hang.
        broker.stop()
        do {
            _ = try await client.run(
                message: "during outage",
                timelineID: timelineID,
                clientTurnID: "boundary-2"
            )
            Issue.record("A Turn succeeded while the broker was down.")
        } catch {
            // Any structured client failure is acceptable; the bound is the contract.
        }

        // The serve runtime must still shut down cleanly while the broker is down.
        await runtime.shutdown()
        await session.stop()

        // Reconnect: a restarted broker and a restarted node serve a fresh session.
        #expect(broker.start())
        let restarted = try await makeRuntime()
        let recoveredSession = try await makeSession()
        let recoveredClient = try recoveredSession.turnClient(timeout: .seconds(5))
        let recovered = try await recoveredClient.run(
            message: "after reconnect",
            timelineID: timelineID,
            clientTurnID: "boundary-3"
        )
        #expect(!recovered.text.isEmpty)

        await recoveredSession.stop()
        await restarted.shutdown()
    }
}
