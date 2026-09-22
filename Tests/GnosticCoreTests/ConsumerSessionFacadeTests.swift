// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

// Consumer-facing tests for the public session facade. This target does not
// depend on the CLI executable, so compiling and passing here proves that an
// external consumer can connect, discover, and read the catalog without the
// CLI module.
//
// The "provider" below is a raw Axoloty host that advertises objects. It is
// not a Gnostic Node: the facade only needs the broker, so discovery and
// catalog reads are exercised without hosting a Node.

@Suite("Consumer session facade", .timeLimit(.minutes(1)))
@MainActor
struct ConsumerSessionFacadeTests {
    private let host = "127.0.0.1"
    private let anonymousPort = 1883
    private let authenticatedPort = 1884
    private let authUsername = "gnostic-test"
    private let authPassword = "gnostic-secret"

    @Test("facade discovers and reads catalog objects without hosting a Node")
    func discoversAndReadsCatalog() async throws {
        let namespace = namespaced("discover")
        let provider = try makeProvider(namespace: namespace)
        try await provider.startAndWaitUntilReady()
        defer { provider.stop() }

        let workspaceID = UUID()
        provider.publishAdvertise(
            GnosticWorkspaceObject(workspace: makeWorkspace(id: workspaceID, uri: "workspace://facade"))
        )

        try await withSession(broker: .init(host: host, port: anonymousPort, namespace: namespace)) { session in
            try await session.discover()

            let entries = await session.networkObjects()
            #expect(entries.contains { $0.objectID == workspaceID && $0.objectType == GnosticObjectType.workspace })

            let entry = await session.object(id: workspaceID, providerID: provider.identity.objectId.string)
            #expect(entry?.objectID == workspaceID)
            #expect(entry?.workspace?.uri == "workspace://facade")
        }
    }

    @Test("facade authenticates broker credentials end to end")
    func authenticatesBrokerCredentials() async throws {
        let namespace = namespaced("credentials")
        let provider = try makeProvider(
            namespace: namespace,
            port: authenticatedPort,
            username: authUsername,
            password: authPassword
        )
        try await provider.startAndWaitUntilReady()
        defer { provider.stop() }

        let workspaceID = UUID()
        provider.publishAdvertise(
            GnosticWorkspaceObject(workspace: makeWorkspace(id: workspaceID, uri: "workspace://credentials"))
        )

        try await withSession(broker: .init(
            host: host,
            port: authenticatedPort,
            namespace: namespace,
            username: authUsername,
            password: authPassword
        )) { session in
            try await session.discover()
            #expect(await session.networkObjects().contains { $0.objectID == workspaceID })
        }
    }

    @Test("facade surfaces a structured error when broker credentials are rejected")
    func rejectsInvalidBrokerCredentials() async throws {
        let session = try GnosticConsumerSession(
            broker: .init(
                host: host,
                port: authenticatedPort,
                namespace: namespaced("rejected"),
                username: authUsername,
                password: "wrong-secret"
            ),
            connectTimeout: .seconds(2)
        )
        await #expect(throws: GnosticConsumerSessionError.self) {
            try await session.start()
        }
        await session.stop()
    }

    @Test("facade rejects a password without a username before connecting")
    func rejectsPasswordWithoutUsername() async throws {
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: anonymousPort, namespace: namespaced("invalid"), password: "secret"),
            connectTimeout: .milliseconds(500)
        )
        do {
            try await session.start()
            Issue.record("expected an invalidCredentials failure")
        } catch let error as GnosticConsumerSessionError {
            #expect(error == .invalidCredentials)
        }
        await session.stop()
    }

    @Test("the consumer facade and its tests do not import the CLI module")
    func consumerFacadeDoesNotImportCLI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // Build the needle so this assertion's own source does not contain it.
        let needle = "import " + "GnosticCLI"

        let facade = try String(
            contentsOf: root.appendingPathComponent("Sources/GnosticCore/Services/GnosticConsumerSession.swift"),
            encoding: .utf8
        )
        #expect(!facade.contains(needle))

        let consumerTest = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        #expect(!consumerTest.contains(needle))
    }

    @Test("empty credential strings are normalized to absent")
    func normalizesEmptyCredentials() {
        let settings = GnosticBrokerSettings(
            host: host,
            port: anonymousPort,
            namespace: "credentials",
            username: "",
            password: ""
        )
        #expect(settings.username == nil)
        #expect(settings.password == nil)
    }

    @Test("facade observes deadvertisement and evicts the object")
    func observesDeadvertisement() async throws {
        let namespace = namespaced("deadvertise")

        // Connect before the provider advertises. Axoloty delivers a
        // deadvertise only to subscribers that observed the advertisement, so
        // the session must be live before the object is advertised.
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: anonymousPort, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(2)
        )
        defer { Task { @MainActor in await session.stop() } }
        try await session.start()

        let provider = try Container.resolve(
            components: Components(
                controllers: ["ObjectLifecycleController": ObjectLifecycleController.self],
                objectTypes: [GnosticWorkspaceObject.self]
            ),
            configuration: Configuration(
                common: CommonOptions(agentIdentity: ["name": "facade-deadvertise-provider"]),
                communication: CommunicationOptions(
                    namespace: namespace,
                    shouldEnableCrossNamespacing: false,
                    mqttClientOptions: MQTTClientOptions(
                        host: host,
                        port: UInt16(anonymousPort),
                        shouldTryMDNSDiscovery: false,
                        autoReconnect: false
                    ),
                    shouldAutoStart: false
                )
            )
        )
        try await provider.startAndWaitUntilReady()
        defer { provider.shutdown() }
        let lifecycle = try #require(
            provider.controller(named: "ObjectLifecycleController") as ObjectLifecycleController?
        )

        let workspaceID = UUID()
        let object = GnosticWorkspaceObject(
            workspace: makeWorkspace(id: workspaceID, uri: "workspace://deadvertise")
        )

        let advertiseStream = await session.catalogUpdates()
        async let advertised = firstChange(in: advertiseStream, timeout: .seconds(5)) { change in
            guard case let .advertised(entry) = change else { return false }
            return entry.objectID == workspaceID
        }
        lifecycle.advertiseDiscoverableObject(object: object)
        #expect(await advertised != nil)

        try await session.discover()
        #expect(await session.networkObjects().contains { $0.objectID == workspaceID })

        let deadvertiseStream = await session.catalogUpdates()
        async let deadvertised = firstChange(in: deadvertiseStream, timeout: .seconds(5)) { change in
            guard case let .deadvertised(objectID, _) = change else { return false }
            return objectID == workspaceID
        }
        lifecycle.deadvertiseDiscoverableObject(object: object)
        #expect(await deadvertised != nil)
        #expect(!(await session.networkObjects().contains { $0.objectID == workspaceID }))

        await session.stop()
    }

    @Test("facade exposes bounded raw advertise events with object metadata")
    func observesRawAdvertiseEvent() async throws {
        let namespace = namespaced("raw-advertise")
        let provider = try makeProvider(namespace: namespace)
        try await provider.startAndWaitUntilReady()
        defer { provider.stop() }

        let workspaceID = UUID()
        try await withSession(broker: .init(host: host, port: anonymousPort, namespace: namespace)) { session in
            let rawEvents = await session.rawEvents()
            async let observed = firstRawEvent(in: rawEvents, timeout: .seconds(5)) { event in
                event.kind == .advertise && event.targetObjectId == workspaceID
            }

            provider.publishAdvertise(
                GnosticWorkspaceObject(workspace: makeWorkspace(id: workspaceID, uri: "workspace://raw-advertise"))
            )

            let event = try #require(await observed)
            #expect(event.objectType == GnosticObjectType.workspace)
            #expect(event.sourceId == provider.identity.objectId.string)
            #expect(event.channelId == nil)
            #expect(event.payload.utf8.count <= GnosticRawWireEvent.maximumPayloadBytes)
        }
    }

    @Test("facade exposes raw discover responses")
    func observesRawDiscoverResponse() async throws {
        let namespace = namespaced("raw-discover")
        let provider = try makeProvider(namespace: namespace)
        try await provider.startAndWaitUntilReady()
        defer { provider.stop() }

        let workspaceID = UUID()
        provider.publishAdvertise(
            GnosticWorkspaceObject(workspace: makeWorkspace(id: workspaceID, uri: "workspace://raw-discover"))
        )

        try await withSession(broker: .init(host: host, port: anonymousPort, namespace: namespace)) { session in
            let rawEvents = await session.rawEvents()
            async let observed = firstRawEvent(in: rawEvents, timeout: .seconds(5)) { event in
                event.kind == .resolve && event.targetObjectId == workspaceID
            }

            try await session.discover()

            let event = try #require(await observed)
            #expect(event.objectType == GnosticObjectType.workspace)
            #expect(event.correlationId != nil)
        }
    }

    @Test("facade observes raw traffic on an arbitrary channel")
    func observesRawChannelEvent() async throws {
        let namespace = namespaced("raw-channel")
        let provider = try makeProvider(namespace: namespace)
        try await provider.startAndWaitUntilReady()
        defer { provider.stop() }

        try await withSession(broker: .init(host: host, port: anonymousPort, namespace: namespace)) { session in
            let channelID = "me.atkn.gnostic.test.channel.\(UUID().uuidString.lowercased())"
            let rawEvents = await session.rawEvents()
            async let observed = firstRawEvent(in: rawEvents, timeout: .seconds(5)) { event in
                event.kind == .channel && event.channelId == channelID
            }

            let object = GnosticWorkspaceObject(workspace: makeWorkspace(id: UUID(), uri: "workspace://raw-channel"))
            provider.publishChannel(try .with(object: object, channelId: channelID))

            let event = try #require(await observed)
            #expect(event.objectType == GnosticObjectType.workspace)
            #expect(event.sourceId == provider.identity.objectId.string)
        }
    }

    @Test("facade emits one raw event per channel delivery")
    func rawChannelEventIsNotDuplicated() async throws {
        let namespace = namespaced("raw-channel-dedup")
        let provider = try makeProvider(namespace: namespace)
        try await provider.startAndWaitUntilReady()
        defer { provider.stop() }

        try await withSession(broker: .init(host: host, port: anonymousPort, namespace: namespace)) { session in
            let channelID = "me.atkn.gnostic.test.channel.\(UUID().uuidString.lowercased())"
            let rawEvents = await session.rawEvents()
            async let collected = collectRawEvents(in: rawEvents, timeout: .milliseconds(800)) { event in
                event.channelId == channelID
            }

            let object = GnosticWorkspaceObject(workspace: makeWorkspace(id: UUID(), uri: "workspace://raw-channel-dedup"))
            provider.publishChannel(try .with(object: object, channelId: channelID))

            #expect(await collected.count == 1)
        }
    }

    @Test("raw event envelope bounds diagnostic payloads")
    func rawEventEnvelopeBoundsPayload() {
        let event = GnosticRawWireEvent(
            kind: .call,
            sourceId: "source",
            correlationId: "correlation",
            payload: String(repeating: "x", count: GnosticRawWireEvent.maximumPayloadBytes + 100)
        )

        #expect(event.payload.utf8.count == GnosticRawWireEvent.maximumPayloadBytes)
    }

    // MARK: - Helpers

    private func namespaced(_ label: String) -> String {
        "gnostic-facade-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func makeWorkspace(id: UUID, uri: String) -> GnosticWorkspaceReference {
        GnosticWorkspaceReference(
            id: id,
            uri: uri,
            tools: [GnosticWorkspaceToolDefinition(id: "echo", name: "Echo", description: "Echoes input.")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeProvider(
        namespace: String,
        port: Int = 1883,
        username: String? = nil,
        password: String? = nil
    ) throws -> CommunicationManager {
        try CommunicationManager(
            identity: Identity(name: "gnostic-facade-provider"),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: host,
                    port: UInt16(port),
                    shouldTryMDNSDiscovery: false,
                    username: username,
                    password: password,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
    }

    /// Returns the first catalog change matching `predicate`, or `nil` once
    /// `timeout` elapses, so a missing lifecycle event fails the test instead
    /// of hanging it.
    nonisolated private func firstChange(
        in stream: AsyncStream<NetworkCatalogChange>,
        timeout: Duration,
        where predicate: @escaping @Sendable (NetworkCatalogChange) -> Bool
    ) async -> NetworkCatalogChange? {
        await withTaskGroup(of: NetworkCatalogChange?.self) { group in
            group.addTask {
                for await change in stream where predicate(change) {
                    return change
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    nonisolated private func collectRawEvents(
        in stream: AsyncStream<GnosticRawWireEvent>,
        timeout: Duration,
        where predicate: @escaping @Sendable (GnosticRawWireEvent) -> Bool
    ) async -> [GnosticRawWireEvent] {
        await withTaskGroup(of: [GnosticRawWireEvent].self) { group in
            group.addTask {
                var matches: [GnosticRawWireEvent] = []
                for await event in stream where predicate(event) {
                    matches.append(event)
                }
                return matches
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            // Whichever finishes first wins the race. The collector only ends
            // when the stream ends or it is cancelled, so cancel it and then
            // read its partial matches.
            var result = await group.next() ?? []
            group.cancelAll()
            if let partial = await group.next(), !partial.isEmpty { result = partial }
            return result
        }
    }

    nonisolated private func firstRawEvent(
        in stream: AsyncStream<GnosticRawWireEvent>,
        timeout: Duration,
        where predicate: @escaping @Sendable (GnosticRawWireEvent) -> Bool
    ) async -> GnosticRawWireEvent? {
        await withTaskGroup(of: GnosticRawWireEvent?.self) { group in
            group.addTask {
                for await event in stream where predicate(event) {
                    return event
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
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
