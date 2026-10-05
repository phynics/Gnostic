// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// Host-level conformance: the invariants ``NodeRuntime`` relies on every
/// backend to satisfy. These checks use a live broker (the container's
/// deterministic Mosquitto), so they run in the container gate.
@MainActor
public struct AscendantHostConformanceSuite: Sendable {
    /// The backend kind and runtime composition under test.
    public let fixture: AscendantHostConformanceFixture

    /// The broker endpoint the host checks connect through.
    public let brokerHost: String
    /// The broker port.
    public let brokerPort: Int

    public init(
        fixture: AscendantHostConformanceFixture,
        brokerHost: String = "127.0.0.1",
        brokerPort: Int = 1883
    ) {
        self.fixture = fixture
        self.brokerHost = brokerHost
        self.brokerPort = brokerPort
    }

    /// Asserts that a lifecycle failure marks health failed, that the next Turn
    /// reconstructs the backend, and that a completed identified Turn replays
    /// after that replacement.
    public func checkHealthQuarantineAndReplay() async throws {
        var checks = AscendantConformanceChecks(kind: fixture.kind)
        let ascendantID = UUID()
        let timelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(
                host: brokerHost,
                port: brokerPort,
                namespace: "conformance-\(fixture.kind)-\(UUID().uuidString.lowercased())"
            ),
            node: .init(id: UUID()),
            ascendants: [.init(
                id: ascendantID,
                name: "Conformance \(fixture.kind)",
                defaultTimelineID: timelineID,
                backend: .init(kind: fixture.kind)
            )],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: fixture.makeAdapters())
        try await runtime.start()

        let probeMessage = "conformance health probe"
        let first = try await runtime.turn(.init(
            message: probeMessage,
            timelineID: timelineID,
            clientTurnID: "conformance-health"
        ))
        checks.require(!first.text.isEmpty, "the first Turn returned no text")
        checks.require(
            await runtime.backendHealth(for: ascendantID) == .healthy,
            "a successful Turn did not leave health healthy"
        )

        await fixture.breakLiveBackend()
        do {
            _ = try await runtime.turn(.init(
                message: "conformance break",
                timelineID: timelineID,
                clientTurnID: "conformance-break"
            ))
            checks.require(false, "a backend reporting lifecycle-unusable served a Turn")
        } catch {
            // The lifecycle failure is expected; health is asserted next.
        }
        checks.require(
            await runtime.backendHealth(for: ascendantID) == .failed,
            "a lifecycle failure did not mark backend health failed"
        )

        do {
            let recovered = try await runtime.turn(.init(
                message: "conformance recovered",
                timelineID: timelineID,
                clientTurnID: "conformance-recovered"
            ))
            checks.require(!recovered.text.isEmpty, "the reconstructed backend returned no text")
        } catch {
            checks.require(false, "the backend was not reconstructed after a lifecycle failure: \(error)")
        }
        checks.require(
            await runtime.backendHealth(for: ascendantID) == .healthy,
            "reconstruction did not restore backend health"
        )

        do {
            let replayed = try await runtime.turn(.init(
                message: probeMessage,
                timelineID: timelineID,
                clientTurnID: "conformance-health"
            ))
            checks.require(replayed.replayed, "a completed identified Turn was not replayed after backend replacement")
            checks.require(replayed.text == first.text, "the replayed Turn returned different text")
        } catch {
            checks.require(false, "replaying a completed identified Turn threw \(error)")
        }

        await runtime.shutdown()
        try checks.finish()
    }
}
