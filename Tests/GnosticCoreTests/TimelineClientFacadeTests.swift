// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

// Consumer-facing tests for the public Timeline client. This file must compile
// against the public `GnosticCore` API alone: it deliberately avoids testable
// imports, so passing here proves that an external consumer can create and
// rename a remote Timeline over a consumer session without the CLI module or a
// second connection.
//
// The serve-side fixture lives in `TimelineClientFacadeBridge.swift`, which
// uses the production `TimelineManagementProvider` handlers. The consumer never
// advertises.

@Suite("Public timeline client", .timeLimit(.minutes(1)))
@MainActor
struct TimelineClientFacadeTests {
    private let host = "127.0.0.1"
    private let port = 1883

    @Test("consumer creates and renames a remote Timeline")
    func createsAndRenamesTimeline() async throws {
        let namespace = namespaced("lifecycle")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            let created = try await client.create(title: "Research", ascendantID: fixture.ascendantID)
            #expect(created.timelineID == fixture.createdTimelineID)
            #expect(created.title == "Research")
            #expect(await fixture.recorder.createTitles == ["Research"])

            let renamed = try await client.update(timelineID: fixture.timelineID, title: "Renamed")
            #expect(renamed.timelineID == fixture.timelineID)
            #expect(renamed.title == "Renamed")
            #expect(await fixture.recorder.updateRequests.first?.timelineID == fixture.timelineID)
            #expect(await fixture.recorder.updateRequests.first?.title == "Renamed")
        }
    }

    @Test("resolves the serving provider from discovery when the catalog is empty")
    func resolvesProviderFromDiscovery() async throws {
        let namespace = namespaced("discovery")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.timelineClient(timeout: .seconds(2))
            let created = try await client.create(title: "Auto", ascendantID: fixture.ascendantID)
            #expect(created.title == "Auto")
            #expect(await fixture.recorder.createTitles == ["Auto"])
        }
    }

    @Test("status reads a discovered Timeline and can address a provider directly")
    func readsTimelineStatus() async throws {
        let namespace = namespaced("status")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.timelineClient(timeout: .seconds(2))

            let discovered = try await client.status(timelineID: fixture.timelineID)
            #expect(discovered.timelineID == fixture.timelineID)
            #expect(discovered.title == "Status")

            // An explicit provider is asked directly, without a catalog lookup.
            let unadvertised = UUID()
            let direct = try await client.status(timelineID: unadvertised, providerID: fixture.providerID)
            #expect(direct.timelineID == unadvertised)
        }
    }

    @Test("create rejects an Ascendant addressed to another provider")
    func createRejectsUnexpectedProvider() async throws {
        let namespace = namespaced("create-mismatch")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            await #expect(throws: GnosticTimelineClientError.providerMismatch) {
                _ = try await client.create(title: "Elsewhere", ascendantID: fixture.ascendantID, providerID: "another-provider")
            }
            #expect(await fixture.recorder.createTitles.isEmpty)
        }
    }

    @Test("maps a create protocol failure to a structured error")
    func createProtocolFailureMapsToStructuredError() async throws {
        let namespace = namespaced("create-conflict")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(create: .protocolFailure)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            await #expect(throws: GnosticTimelineClientError
                .callFailed(reasonCode: "timelineConflict", statusCode: 409, retryable: false)) {
                _ = try await client.create(title: "Conflict", ascendantID: fixture.ascendantID)
            }
        }
    }

    @Test("maps an update protocol failure to a structured error")
    func updateProtocolFailureMapsToStructuredError() async throws {
        let namespace = namespaced("update-missing")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(update: .protocolFailure)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            await #expect(throws: GnosticTimelineClientError
                .callFailed(reasonCode: "timelineNotFound", statusCode: 404, retryable: false)) {
                _ = try await client.update(timelineID: fixture.timelineID, title: "Nope")
            }
        }
    }

    @Test("maps a missing responder to a retryable timeout")
    func missingResponderMapsToTimeout() async throws {
        let namespace = namespaced("create-timeout")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(create: .timeout)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .milliseconds(300))

            await #expect(throws: GnosticTimelineClientError
                .callFailed(reasonCode: "callTimedOut", statusCode: 504, retryable: true)) {
                _ = try await client.create(title: "Slow", ascendantID: fixture.ascendantID)
            }
        }
    }

    @Test("a response from a different provider is rejected")
    func forgedResponseProviderIsRejected() async throws {
        let namespace = namespaced("forged-provider")
        let fixture = try await TimelineClientFacadeBridge.makeForgedResponseFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            await #expect(throws: GnosticTimelineClientError.providerMismatch) {
                _ = try await client.create(title: "Forged", ascendantID: fixture.ascendantID)
            }
        }
    }

    @Test("an Ascendant without timeline management is rejected")
    func missingCapabilityIsRejected() async throws {
        let namespace = namespaced("capability")
        let fixture = try await TimelineClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(capabilities: [])
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            await #expect(throws: GnosticTimelineClientError
                .missingCapability(GnosticCapability.timelineManagement)) {
                _ = try await client.create(title: "Gated", ascendantID: fixture.ascendantID)
            }
            await #expect(throws: GnosticTimelineClientError
                .missingCapability(GnosticCapability.timelineManagement)) {
                _ = try await client.update(timelineID: fixture.timelineID, title: "Gated")
            }
        }
    }

    @Test("an undiscovered Ascendant is rejected")
    func undiscoveredAscendantIsRejected() async throws {
        let namespace = namespaced("missing-ascendant")
        let ascendantID = UUID()

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.timelineClient(timeout: .milliseconds(300))
            await #expect(throws: GnosticTimelineClientError.ascendantUnavailable(ascendantID)) {
                _ = try await client.create(title: "Missing", ascendantID: ascendantID)
            }
        }
    }

    @Test("an undiscovered Timeline is rejected")
    func undiscoveredTimelineIsRejected() async throws {
        let namespace = namespaced("missing-timeline")
        let timelineID = UUID()

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.timelineClient(timeout: .milliseconds(300))
            await #expect(throws: GnosticTimelineClientError.timelineUnavailable(timelineID)) {
                _ = try await client.update(timelineID: timelineID, title: "Missing")
            }
        }
    }

    @Test("an Ascendant advertised by two providers is ambiguous")
    func ambiguousAscendantIsRejected() async throws {
        let namespace = namespaced("ambiguous-ascendant")
        let fixture = try await TimelineClientFacadeBridge.makeAmbiguousAscendantFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            await #expect(throws: GnosticTimelineClientError.ascendantAmbiguous(fixture.ascendantID)) {
                _ = try await client.create(title: "Ambiguous", ascendantID: fixture.ascendantID)
            }
        }
    }

    @Test("a Timeline advertised by two providers is ambiguous")
    func ambiguousTimelineIsRejected() async throws {
        let namespace = namespaced("ambiguous-timeline")
        let fixture = try await TimelineClientFacadeBridge.makeAmbiguousTimelineFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.timelineClient(timeout: .seconds(2))

            await #expect(throws: GnosticTimelineClientError.timelineAmbiguous(fixture.timelineID)) {
                _ = try await client.update(timelineID: fixture.timelineID, title: "Ambiguous")
            }
        }
    }

    @Test("timeline client requires a running session")
    func requiresRunningSession() async throws {
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: port, namespace: namespaced("not-started")),
            connectTimeout: .milliseconds(500)
        )
        defer { Task { @MainActor in await session.stop() } }

        do {
            _ = try session.timelineClient()
            Issue.record("a timeline client was created without a running session")
        } catch let error as GnosticConsumerSessionError {
            #expect(error == .notStarted)
        }
    }

    @Test("reason codes are stable")
    func reasonCodesAreStable() {
        let id = UUID()
        #expect(GnosticTimelineClientError.ascendantUnavailable(id).reasonCode == "ascendantUnavailable")
        #expect(GnosticTimelineClientError.ascendantAmbiguous(id).reasonCode == "ascendantAmbiguous")
        #expect(GnosticTimelineClientError.timelineUnavailable(id).reasonCode == "timelineUnavailable")
        #expect(GnosticTimelineClientError.timelineAmbiguous(id).reasonCode == "timelineAmbiguous")
        #expect(GnosticTimelineClientError.providerMismatch.reasonCode == "providerMismatch")
        #expect(GnosticTimelineClientError.missingCapability("capability").reasonCode == "missingCapability")
        #expect(GnosticTimelineClientError
            .callFailed(reasonCode: "timelineConflict", statusCode: 409, retryable: false)
            .reasonCode == "timelineConflict")
    }

    private func namespaced(_ label: String) -> String {
        "gnostic-timeline-client-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func withSession(
        broker: GnosticBrokerSettings,
        connectTimeout: Duration = .seconds(3),
        discoverTimeout: Duration = .seconds(2),
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
