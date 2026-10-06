// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

// Consumer-facing tests for the public live-diagnostics client. This file
// compiles against the public GnosticCore API alone and avoids testable
// imports where possible, so passing here proves that an external consumer can
// read payload-free Node, Ascendant, and Timeline diagnostics over a consumer
// session, and that a Node without the diagnostics capability degrades clearly
// before any wire call.

@Suite("Public diagnostics client", .timeLimit(.minutes(1)))
@MainActor
struct DiagnosticsClientFacadeTests {
    private let host = "127.0.0.1"
    private let port = 1883

    @Test("reads node, ascendant, and timeline diagnostics without a payload")
    func readsDiagnosticsWithoutPayload() async throws {
        let namespace = namespaced("read")
        let ascendantID = UUID()
        let timelineID = UUID()
        let workspaceID = UUID()
        let provider = try await startProvider(
            namespace: namespace,
            ascendantID: ascendantID,
            timelineID: timelineID,
            capabilities: [GnosticCapability.diagnostics]
        )
        defer { provider.manager.stop() }
        let node = nodeSnapshot(ascendantID: ascendantID, timelineID: timelineID, workspaceID: workspaceID)
        let ascendant = ascendantSnapshot(ascendantID: ascendantID, timelineID: timelineID)
        let timeline = TimelineDiagnostics(
            timeline: DiagnosticsTimelineSummary(id: timelineID, title: "Diagnostics Timeline", operatingAscendantID: ascendantID),
            workspaces: [DiagnosticsWorkspaceSummary(id: workspaceID, uri: "workspace://alpha", status: .available)]
        )
        let registrations = try await registerDiagnostics(
            on: provider.manager,
            node: node,
            ascendant: ascendant,
            timeline: timeline
        )
        defer { registrations.forEach { $0.cancel() } }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.diagnosticsClient(timeout: .seconds(2))

            let readNode = try await client.node()
            #expect(readNode == node)

            let readAscendant = try await client.ascendant(ascendantID)
            #expect(readAscendant == ascendant)

            let readTimeline = try await client.timeline(timelineID)
            #expect(readTimeline == timeline)
        }
    }

    @Test("degrades clearly when no provider advertises diagnostics")
    func degradesWhenCapabilityIsMissing() async throws {
        let namespace = namespaced("missing-capability")
        let provider = try await startProvider(namespace: namespace, capabilities: [GnosticCapability.textTurnInput])
        defer { provider.manager.stop() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.diagnosticsClient(timeout: .seconds(1))
            do {
                _ = try await client.node()
                Issue.record("a Node without the diagnostics capability was accepted")
            } catch let error as GnosticDiagnosticsClientError {
                #expect(error == .missingCapability(GnosticCapability.diagnostics))
                #expect(error.reasonCode == "missingCapability")
            }
        }
    }

    @Test("reports node ambiguity when two providers advertise diagnostics")
    func reportsNodeAmbiguity() async throws {
        let namespace = namespaced("ambiguous")
        let first = try await startProvider(
            namespace: namespace,
            name: "gnostic-diagnostics-provider-a",
            capabilities: [GnosticCapability.diagnostics]
        )
        defer { first.manager.stop() }
        let second = try await startProvider(
            namespace: namespace,
            name: "gnostic-diagnostics-provider-b",
            capabilities: [GnosticCapability.diagnostics]
        )
        defer { second.manager.stop() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.diagnosticsClient(timeout: .seconds(1))
            do {
                _ = try await client.node()
                Issue.record("an ambiguous Node diagnostics target was accepted")
            } catch let error as GnosticDiagnosticsClientError {
                #expect(error == .nodeAmbiguous)
            }
        }
    }

    @Test("rejects an unadvertised Ascendant")
    func rejectsUnadvertisedAscendant() async throws {
        let namespace = namespaced("unadvertised")
        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.diagnosticsClient(timeout: .milliseconds(300))
            let ascendantID = UUID()
            do {
                _ = try await client.ascendant(ascendantID)
                Issue.record("an unadvertised Ascendant was accepted")
            } catch let error as GnosticDiagnosticsClientError {
                #expect(error == .ascendantUnavailable(ascendantID))
            }
        }
    }

    @Test("rejects an explicit provider that does not own the Ascendant")
    func rejectsProviderMismatch() async throws {
        let namespace = namespaced("mismatch")
        let provider = try await startProvider(namespace: namespace, capabilities: [GnosticCapability.diagnostics])
        defer { provider.manager.stop() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.diagnosticsClient(timeout: .seconds(1))
            do {
                _ = try await client.ascendant(provider.ascendantID, providerID: UUID().uuidString)
                Issue.record("a provider that does not own the Ascendant was accepted")
            } catch let error as GnosticDiagnosticsClientError {
                #expect(error == .providerMismatch)
            }
        }
    }

    @Test("maps a serve protocol failure to a structured error")
    func mapsServeFailureToStructuredError() async throws {
        let namespace = namespaced("serve-failure")
        let provider = try await startProvider(namespace: namespace, capabilities: [GnosticCapability.diagnostics])
        defer { provider.manager.stop() }
        let registration = try await provider.manager.registerCallHandler(
            operation: DiagnosticsProvider.nodeOperation
        ) { _ in
            .failure(
                code: 409,
                message: GnosticProtocol.failureMessage(
                    reasonCode: "diagnosticsConflict",
                    message: "The diagnostics read conflicted with a lifecycle change.",
                    statusCode: 409
                )
            )
        }
        defer { registration.cancel() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.diagnosticsClient(timeout: .seconds(1))
            do {
                _ = try await client.node(providerID: provider.providerID)
                Issue.record("a failed diagnostics read did not throw")
            } catch let error as GnosticDiagnosticsClientError {
                #expect(error == .callFailed(reasonCode: "diagnosticsConflict", statusCode: 409, retryable: false))
                #expect(error.reasonCode == "diagnosticsConflict")
            }
        }
    }

    @Test("diagnostics client requires a running session")
    func requiresRunningSession() async throws {
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: port, namespace: namespaced("not-started")),
            connectTimeout: .milliseconds(500)
        )
        defer { Task { @MainActor in await session.stop() } }

        do {
            _ = try session.diagnosticsClient()
            Issue.record("a diagnostics client was created without a running session")
        } catch let error as GnosticConsumerSessionError {
            #expect(error == .notStarted)
        }
    }

    @Test("reason codes are stable")
    func reasonCodesAreStable() {
        let id = UUID()
        #expect(GnosticDiagnosticsClientError.missingCapability("capability").reasonCode == "missingCapability")
        #expect(GnosticDiagnosticsClientError.nodeUnavailable.reasonCode == "nodeUnavailable")
        #expect(GnosticDiagnosticsClientError.nodeAmbiguous.reasonCode == "nodeAmbiguous")
        #expect(GnosticDiagnosticsClientError.ascendantUnavailable(id).reasonCode == "ascendantUnavailable")
        #expect(GnosticDiagnosticsClientError.ascendantAmbiguous(id).reasonCode == "ascendantAmbiguous")
        #expect(GnosticDiagnosticsClientError.timelineUnavailable(id).reasonCode == "timelineUnavailable")
        #expect(GnosticDiagnosticsClientError.timelineAmbiguous(id).reasonCode == "timelineAmbiguous")
        #expect(GnosticDiagnosticsClientError.providerMismatch.reasonCode == "providerMismatch")
        #expect(GnosticDiagnosticsClientError
            .callFailed(reasonCode: "diagnosticsConflict", statusCode: 409, retryable: true)
            .reasonCode == "diagnosticsConflict")
    }

    private struct AdvertisedProvider {
        let manager: CommunicationManager
        let providerID: String
        let ascendantID: UUID
        let timelineID: UUID
    }

    private func nodeSnapshot(ascendantID: UUID, timelineID: UUID, workspaceID: UUID) -> NodeDiagnostics {
        NodeDiagnostics(
            nodeID: UUID(),
            ascendents: [
                DiagnosticsAscendantSummary(id: ascendantID, name: "Diagnostics Ascendant", health: .healthy, quarantined: false),
            ],
            timelines: [
                DiagnosticsTimelineSummary(id: timelineID, title: "Diagnostics Timeline", operatingAscendantID: ascendantID),
            ],
            workspaces: [
                DiagnosticsWorkspaceSummary(id: workspaceID, uri: "workspace://alpha", status: .available),
            ],
            turns: DiagnosticsTurnCounters(inFlight: 1, completed: 2, observationPending: 0, observationClosed: true),
            observer: DiagnosticsObserverDrain(
                liveObservations: 0,
                cleanupFailures: 0,
                retainedInFlight: 1,
                retainedCompleted: 2,
                retainedTombstones: 0
            )
        )
    }

    private func ascendantSnapshot(ascendantID: UUID, timelineID: UUID) -> AscendantDiagnostics {
        AscendantDiagnostics(
            ascendant: DiagnosticsAscendantSummary(id: ascendantID, name: "Diagnostics Ascendant", health: .healthy, quarantined: false),
            description: "Offline diagnostics provider.",
            backendKind: "test",
            backendVersion: "1.0.0",
            capabilities: [GnosticCapability.diagnostics],
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            timelines: []
        )
    }

    private func registerDiagnostics(
        on manager: CommunicationManager,
        node: NodeDiagnostics,
        ascendant: AscendantDiagnostics,
        timeline: TimelineDiagnostics
    ) async throws -> [CallHandlerRegistration] {
        let nodeRegistration = try await manager.registerCallHandler(
            operation: DiagnosticsProvider.nodeOperation
        ) { _ in
            try .success(result: String(decoding: GnosticWirePayload.encode(node, context: "test node diagnostics"), as: UTF8.self))
        }
        let ascendantRegistration = try await manager.registerCallHandler(
            operation: DiagnosticsProvider.ascendantOperation
        ) { _ in
            try .success(result: String(decoding: GnosticWirePayload.encode(ascendant, context: "test ascendant diagnostics"), as: UTF8.self))
        }
        let timelineRegistration = try await manager.registerCallHandler(
            operation: DiagnosticsProvider.timelineOperation
        ) { _ in
            try .success(result: String(decoding: GnosticWirePayload.encode(timeline, context: "test timeline diagnostics"), as: UTF8.self))
        }
        return [nodeRegistration, ascendantRegistration, timelineRegistration]
    }

    private func namespaced(_ label: String) -> String {
        "gnostic-diagnostics-client-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func makeProvider(namespace: String, name: String) throws -> CommunicationManager {
        try CommunicationManager(
            identity: Identity(name: name),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: host,
                    port: UInt16(port),
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
    }

    private func startProvider(
        namespace: String,
        name: String = "gnostic-diagnostics-provider",
        ascendantID: UUID = UUID(),
        timelineID: UUID = UUID(),
        capabilities: [String] = [GnosticCapability.diagnostics]
    ) async throws -> AdvertisedProvider {
        let manager = try makeProvider(namespace: namespace, name: name)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        manager.publishAdvertise(GnosticAscendantObject(identity: AscendantBackendIdentity(
            id: ascendantID,
            name: "Diagnostics Ascendant",
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
            title: "Diagnostics Timeline",
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

    private func withSession(
        broker: GnosticBrokerSettings,
        connectTimeout: Duration = .seconds(3),
        discoverTimeout: Duration = .seconds(1),
        _ body: (GnosticConsumerSession) async throws -> Void
    ) async throws {
        let session = try GnosticConsumerSession(
            broker: broker,
            connectTimeout: connectTimeout,
            discoverTimeout: discoverTimeout
        )
        do {
            try await session.start()
            try await body(session)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }
}
