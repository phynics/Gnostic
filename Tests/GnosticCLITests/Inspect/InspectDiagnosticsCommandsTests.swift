// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("Inspect diagnostics commands", .timeLimit(.minutes(1)))
@MainActor
struct InspectDiagnosticsCommandsTests {
    @Test("reads live node diagnostics through the CLI session without a payload")
    func readsNodeDiagnosticsThroughSession() async throws {
        let namespace = uniqueNamespace()
        let provider = try await startProvider(namespace: namespace, capabilities: [GnosticCapability.diagnostics])
        defer { provider.manager.stop() }
        let secret = "sk-live-SUPERSECRET"
        let snapshot = NodeDiagnostics(
            nodeID: UUID(),
            ascendents: [
                DiagnosticsAscendantSummary(id: provider.ascendantID, name: "CLI Ascendant", health: .healthy, quarantined: false),
            ],
            timelines: [
                DiagnosticsTimelineSummary(
                    id: provider.timelineID,
                    title: "CLI Timeline",
                    operatingAscendantID: provider.ascendantID
                ),
            ],
            workspaces: [],
            turns: DiagnosticsTurnCounters(inFlight: 0, completed: 1, observationPending: 0, observationClosed: true),
            observer: DiagnosticsObserverDrain(
                liveObservations: 0,
                cleanupFailures: 0,
                retainedInFlight: 0,
                retainedCompleted: 1,
                retainedTombstones: 0
            )
        )
        let registration = try await provider.manager.registerCallHandler(
            operation: DiagnosticsProvider.nodeOperation
        ) { _ in
            try .success(result: String(decoding: GnosticWirePayload.encode(snapshot, context: "test node diagnostics"), as: UTF8.self))
        }
        defer { registration.cancel() }

        let read = try await InspectDiagnosticsSession(values: connectionValues(namespace: namespace))
            .node(providerID: provider.providerID)
        #expect(read == snapshot)

        let text = InspectRenderer.nodeText(read)
        #expect(text.contains("CLI Ascendant"))
        #expect(!text.contains(secret))

        let json = try InspectRenderer.diagnosticsJSON(read)
        #expect(!json.contains(secret))
        #expect(!json.contains("\"payload\""))
    }

    @Test("degrades clearly when the Node lacks the diagnostics capability")
    func degradesWhenCapabilityIsMissing() async throws {
        let namespace = uniqueNamespace()
        let provider = try await startProvider(namespace: namespace, capabilities: [GnosticCapability.textTurnInput])
        defer { provider.manager.stop() }

        do {
            _ = try await InspectDiagnosticsSession(values: connectionValues(namespace: namespace))
                .node(providerID: provider.providerID)
            Issue.record("a Node without the diagnostics capability was accepted")
        } catch let error as InspectError {
            #expect(error.reasonCode == "diagnosticsCapabilityUnavailable")
            #expect(error.errorDescription?.contains(GnosticCapability.diagnostics) == true)
        }
    }

    private func uniqueNamespace() -> String {
        "gnostic-inspect-diagnostics-\(UUID().uuidString.lowercased())"
    }

    private func connectionValues(namespace: String) -> InspectConnectionValues {
        InspectConnectionValues(host: "127.0.0.1", port: 1883, namespace: namespace, observeSeconds: 1.5)
    }

    private struct AdvertisedProvider {
        let manager: CommunicationManager
        let providerID: String
        let ascendantID: UUID
        let timelineID: UUID
    }

    private func startProvider(namespace: String, capabilities: [String]) async throws -> AdvertisedProvider {
        let manager = try CommunicationManager(
            identity: Identity(name: "gnostic-inspect-diagnostics-provider"),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: "127.0.0.1",
                    port: 1883,
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ascendantID = UUID()
        let timelineID = UUID()
        manager.publishAdvertise(GnosticAscendantObject(identity: AscendantBackendIdentity(
            id: ascendantID,
            name: "CLI Ascendant",
            description: "Offline diagnostics provider.",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: AscendantBackendCapabilities(interoperability: Set(capabilities))
        )))
        manager.publishAdvertise(GnosticTimelineObject(timeline: AscendantBackendTimeline(
            id: timelineID,
            title: "CLI Timeline",
            attachedWorkspaceIDs: [],
            attachedAscendantID: ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )))
        try await manager.startAndWaitUntilReady()
        return AdvertisedProvider(
            manager: manager,
            providerID: manager.identity.objectId.string,
            ascendantID: ascendantID,
            timelineID: timelineID
        )
    }
}
