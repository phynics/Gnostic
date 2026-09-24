// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore

/// Test-only serve-side scaffolding for the public Timeline client tests.
///
/// This file uses the production `TimelineManagementProvider` wire handlers and
/// the production advertisement projections so the consumer-facing
/// `TimelineClientFacadeTests.swift` can compile against the public
/// `GnosticCore` API alone. The provider below is a raw Axoloty host, not a
/// Gnostic Node; the consumer never advertises.
@MainActor
enum TimelineClientFacadeBridge {
    enum Outcome {
        case accept
        case protocolFailure
        case timeout
    }

    struct Options {
        var capabilities: Set<String> = [GnosticCapability.timelineManagement]
        var create: Outcome = .accept
        var update: Outcome = .accept
    }

    struct Fixture {
        let managers: [CommunicationManager]
        let ascendantID: UUID
        let timelineID: UUID
        let createdTimelineID: UUID
        let providerID: String
        let recorder: TimelineFixtureRecorder
        let registrations: [CallHandlerRegistration]

        var manager: CommunicationManager { managers[0] }

        @MainActor
        func teardown() {
            registrations.forEach { $0.cancel() }
            for manager in managers { manager.stop() }
        }
    }

    static func makeFixture(
        namespace: String,
        host: String,
        port: Int,
        options: Options = Options()
    ) async throws -> Fixture {
        let manager = try makeManager(name: "gnostic-timeline-client-provider", namespace: namespace, host: host, port: port)
        let ascendantID = UUID()
        let timelineID = UUID()
        let createdTimelineID = UUID()
        let recorder = TimelineFixtureRecorder()

        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: options.capabilities,
            on: manager
        )

        let provider = TimelineManagementProvider(
            create: { title, _ in
                await recorder.recordCreate(title: title)
                return TimelineStatus(timelineID: createdTimelineID, title: title, attachedWorkspaceIDs: [])
            },
            list: { [] },
            update: { request in
                await recorder.recordUpdate(request)
                return TimelineStatus(timelineID: request.timelineID, title: request.title, attachedWorkspaceIDs: [])
            }
        )

        var registrations: [CallHandlerRegistration] = []
        if options.create != .timeout {
            registrations.append(try await registerCreate(on: manager, provider: provider, outcome: options.create))
        }
        if options.update != .timeout {
            registrations.append(try await registerUpdate(on: manager, provider: provider, outcome: options.update))
        }
        let status = TimelineStatusProvider { request in
            TimelineStatus(timelineID: request.timelineID, title: "Status", attachedWorkspaceIDs: [])
        }
        registrations.append(try await status.register(on: manager, context: manager.identity))

        try await start(manager)
        return Fixture(
            managers: [manager],
            ascendantID: ascendantID,
            timelineID: timelineID,
            createdTimelineID: createdTimelineID,
            providerID: manager.identity.objectId.string,
            recorder: recorder,
            registrations: registrations
        )
    }

    /// Two providers advertise the same Ascendant identifier, so resolution
    /// reports the Ascendant as ambiguous.
    static func makeAmbiguousAscendantFixture(
        namespace: String,
        host: String,
        port: Int
    ) async throws -> Fixture {
        let first = try makeManager(name: "ascendant-ambiguous-a", namespace: namespace, host: host, port: port)
        let second = try makeManager(name: "ascendant-ambiguous-b", namespace: namespace, host: host, port: port)
        let ascendantID = UUID()
        let timelineID = UUID()
        let createdTimelineID = UUID()

        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: [GnosticCapability.timelineManagement],
            on: first
        )
        advertiseTimeline(
            timelineID: UUID(),
            ascendantID: ascendantID,
            capabilities: [GnosticCapability.timelineManagement],
            on: second
        )

        try await start(first)
        try await start(second)
        return Fixture(
            managers: [first, second],
            ascendantID: ascendantID,
            timelineID: timelineID,
            createdTimelineID: createdTimelineID,
            providerID: first.identity.objectId.string,
            recorder: TimelineFixtureRecorder(),
            registrations: []
        )
    }

    /// Two providers advertise the same Timeline identifier, so resolution
    /// reports the Timeline as ambiguous.
    static func makeAmbiguousTimelineFixture(
        namespace: String,
        host: String,
        port: Int
    ) async throws -> Fixture {
        let first = try makeManager(name: "timeline-ambiguous-a", namespace: namespace, host: host, port: port)
        let second = try makeManager(name: "timeline-ambiguous-b", namespace: namespace, host: host, port: port)
        let ascendantID = UUID()
        let timelineID = UUID()

        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: [GnosticCapability.timelineManagement],
            on: first
        )
        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: UUID(),
            capabilities: [GnosticCapability.timelineManagement],
            on: second
        )

        try await start(first)
        try await start(second)
        return Fixture(
            managers: [first, second],
            ascendantID: ascendantID,
            timelineID: timelineID,
            createdTimelineID: UUID(),
            providerID: first.identity.objectId.string,
            recorder: TimelineFixtureRecorder(),
            registrations: []
        )
    }

    /// A second provider answers calls addressed to the first provider, so the
    /// response source does not match the selected provider.
    static func makeForgedResponseFixture(
        namespace: String,
        host: String,
        port: Int
    ) async throws -> Fixture {
        let first = try makeManager(name: "timeline-forged-target", namespace: namespace, host: host, port: port)
        let second = try makeManager(name: "timeline-forged-responder", namespace: namespace, host: host, port: port)
        let ascendantID = UUID()
        let timelineID = UUID()

        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: [GnosticCapability.timelineManagement],
            on: first
        )

        let registration = try await second.registerCallHandler(
            operation: TimelineManagementProvider.createOperation,
            context: first.identity
        ) { _ in
            .success(result: try Self.encodeStatus(timelineID: UUID(), title: "Forged"))
        }

        try await start(first)
        try await start(second)
        return Fixture(
            managers: [first, second],
            ascendantID: ascendantID,
            timelineID: timelineID,
            createdTimelineID: UUID(),
            providerID: first.identity.objectId.string,
            recorder: TimelineFixtureRecorder(),
            registrations: [registration]
        )
    }

    private static func registerCreate(
        on manager: CommunicationManager,
        provider: TimelineManagementProvider,
        outcome: Outcome
    ) async throws -> CallHandlerRegistration {
        try await manager.registerCallHandler(operation: TimelineManagementProvider.createOperation) { snapshot in
            switch outcome {
            case .accept:
                return try await provider.handle(
                    operation: TimelineManagementProvider.createOperation,
                    parameters: snapshot.parameters
                )
            case .protocolFailure:
                return .failure(
                    code: 409,
                    message: GnosticProtocol.failureMessage(
                        reasonCode: "timelineConflict",
                        message: "The Timeline already exists.",
                        statusCode: 409
                    )
                )
            case .timeout:
                return .failure(code: 500, message: "unreachable")
            }
        }
    }

    private static func registerUpdate(
        on manager: CommunicationManager,
        provider: TimelineManagementProvider,
        outcome: Outcome
    ) async throws -> CallHandlerRegistration {
        try await manager.registerCallHandler(operation: TimelineManagementProvider.updateOperation) { snapshot in
            switch outcome {
            case .accept:
                return try await provider.handle(
                    operation: TimelineManagementProvider.updateOperation,
                    parameters: snapshot.parameters
                )
            case .protocolFailure:
                return .failure(
                    code: 404,
                    message: GnosticProtocol.failureMessage(
                        reasonCode: "timelineNotFound",
                        message: "The Timeline does not exist.",
                        statusCode: 404
                    )
                )
            case .timeout:
                return .failure(code: 500, message: "unreachable")
            }
        }
    }

    private static func advertiseTimeline(
        timelineID: UUID,
        ascendantID: UUID,
        capabilities: Set<String>,
        on manager: CommunicationManager
    ) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        manager.publishAdvertise(GnosticAscendantObject(identity: AscendantBackendIdentity(
            id: ascendantID,
            name: "Timeline Ascendant",
            description: "Offline Timeline provider.",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: AscendantBackendCapabilities(interoperability: capabilities)
        )))
        manager.publishAdvertise(GnosticTimelineObject(timeline: AscendantBackendTimeline(
            id: timelineID,
            title: "Timeline",
            attachedWorkspaceIDs: [],
            attachedAscendantID: ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )))
    }

    private nonisolated static func encodeStatus(timelineID: UUID, title: String) throws -> String {
        String(decoding: try JSONEncoder().encode(
            TimelineStatus(timelineID: timelineID, title: title, attachedWorkspaceIDs: [])
        ), as: UTF8.self)
    }

    private static func makeManager(
        name: String,
        namespace: String,
        host: String,
        port: Int
    ) throws -> CommunicationManager {
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

    private static func start(_ manager: CommunicationManager) async throws {
        let stream = await manager.observeCommunicationStateStream()
        var iterator = stream.makeAsyncIterator()
        try manager.start()
        while let state = await iterator.next() {
            if state == .online { return }
        }
        throw CancellationError()
    }
}

/// Records create and update requests observed by the fixture serve.
actor TimelineFixtureRecorder {
    private(set) var createTitles: [String] = []
    private(set) var updateRequests: [TimelineUpdateRequest] = []

    func recordCreate(title: String) {
        createTitles.append(title)
    }

    func recordUpdate(_ request: TimelineUpdateRequest) {
        updateRequests.append(request)
    }
}
