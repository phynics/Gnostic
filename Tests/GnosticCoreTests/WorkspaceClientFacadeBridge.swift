// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts

/// Test-only serve-side scaffolding for the public workspace client tests.
///
/// This file uses the production wire providers and PositronicKit workspace
/// values so the consumer-facing `WorkspaceClientFacadeTests.swift` can compile
/// against the public `GnosticCore` API alone.
@MainActor
enum WorkspaceClientFacadeBridge {
    enum MutateOutcome {
        case accept
        case reject
        case protocolFailure
    }

    enum InvokeOutcome {
        case echo
        case toolFailure
        case protocolFailure
        case malformedResult
        case timeout
    }

    struct Options {
        var capabilities: Set<String> = Self.defaultCapabilities
        var attach: MutateOutcome = .accept
        var detach: MutateOutcome = .accept
        var invoke: InvokeOutcome = .echo

        static let defaultCapabilities: Set<String> = [
            GnosticCapability.textTurnInput,
            GnosticCapability.workspaceAttachment,
            GnosticCapability.workspaceToolInvocation,
        ]
    }

    struct Fixture {
        let managers: [CommunicationManager]
        let workspaceID: UUID
        let timelineID: UUID
        let ascendantID: UUID
        let providerID: String
        let workspaceURI: String
        let recorder: WorkspaceFixtureRecorder
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
        let manager = try makeManager(name: "gnostic-workspace-client-provider", namespace: namespace, host: host, port: port)
        let workspaceID = UUID()
        let timelineID = UUID()
        let ascendantID = UUID()
        let workspaceURI = "workspace://fixture"

        advertiseWorkspace(workspaceID, uri: workspaceURI, on: manager)
        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: options.capabilities,
            on: manager
        )

        let recorder = WorkspaceFixtureRecorder()
        var registrations: [CallHandlerRegistration] = []
        let usesRawMutations = options.attach == .protocolFailure || options.detach == .protocolFailure
        if usesRawMutations {
            registrations.append(try await registerRawMutation(on: manager, mutation: .attach, outcome: options.attach, recorder: recorder))
            registrations.append(try await registerRawMutation(on: manager, mutation: .detach, outcome: options.detach, recorder: recorder))
        } else {
            let operations = WorkspaceOpsProvider(
                list: { [] },
                attach: { request in
                    await recorder.recordAttach(request)
                    return options.attach == .accept
                },
                detach: { request in
                    await recorder.recordDetach(request)
                    return options.detach == .accept
                }
            )
            registrations.append(contentsOf: try await operations.register(on: manager))
        }
        registrations.append(contentsOf: try await registerInvocation(
            workspaceID: workspaceID,
            outcome: options.invoke,
            on: manager
        ))

        try await start(manager)
        return Fixture(
            managers: [manager],
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            providerID: manager.identity.objectId.string,
            workspaceURI: workspaceURI,
            recorder: recorder,
            registrations: registrations
        )
    }

    /// Two providers advertise the same Workspace identifier, so discovery
    /// reports the Workspace as ambiguous.
    static func makeAmbiguousWorkspaceFixture(
        namespace: String,
        host: String,
        port: Int
    ) async throws -> Fixture {
        let first = try makeManager(name: "workspace-ambiguous-a", namespace: namespace, host: host, port: port)
        let second = try makeManager(name: "workspace-ambiguous-b", namespace: namespace, host: host, port: port)
        let workspaceID = UUID()
        let timelineID = UUID()
        let ascendantID = UUID()
        let workspaceURI = "workspace://ambiguous"

        advertiseWorkspace(workspaceID, uri: workspaceURI, on: first)
        advertiseWorkspace(workspaceID, uri: workspaceURI, on: second)
        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: Options.defaultCapabilities,
            on: first
        )

        let recorder = WorkspaceFixtureRecorder()
        var registrations: [CallHandlerRegistration] = []
        let operations = WorkspaceOpsProvider(
            list: { [] },
            attach: { request in
                await recorder.recordAttach(request)
                return true
            },
            detach: { request in
                await recorder.recordDetach(request)
                return true
            }
        )
        registrations.append(contentsOf: try await operations.register(on: first))

        try await start(first)
        try await start(second)
        return Fixture(
            managers: [first, second],
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            providerID: first.identity.objectId.string,
            workspaceURI: workspaceURI,
            recorder: recorder,
            registrations: registrations
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
        let workspaceID = UUID()
        let timelineID = UUID()
        let ascendantID = UUID()
        let workspaceURI = "workspace://timeline-ambiguous"

        advertiseWorkspace(workspaceID, uri: workspaceURI, on: first)
        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: Options.defaultCapabilities,
            on: first
        )
        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: UUID(),
            capabilities: Options.defaultCapabilities,
            on: second
        )

        let recorder = WorkspaceFixtureRecorder()
        try await start(first)
        try await start(second)
        return Fixture(
            managers: [first, second],
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            providerID: first.identity.objectId.string,
            workspaceURI: workspaceURI,
            recorder: recorder,
            registrations: []
        )
    }

    /// A second provider answers calls addressed to the first provider, so the
    /// response source does not match the addressed provider.
    static func makeForgedAttachFixture(
        namespace: String,
        host: String,
        port: Int
    ) async throws -> Fixture {
        let first = try makeManager(name: "workspace-forged-target", namespace: namespace, host: host, port: port)
        let second = try makeManager(name: "workspace-forged-responder", namespace: namespace, host: host, port: port)
        let workspaceID = UUID()
        let timelineID = UUID()
        let ascendantID = UUID()
        let workspaceURI = "workspace://forged"

        advertiseWorkspace(workspaceID, uri: workspaceURI, on: first)
        advertiseTimeline(
            timelineID: timelineID,
            ascendantID: ascendantID,
            capabilities: Options.defaultCapabilities,
            on: first
        )

        let registration = try await second.registerCallHandler(
            operation: WorkspaceOpsProvider.attachOperation,
            context: first.identity
        ) { _ in
            .success(result: try Self.encodeMutation(accepted: true))
        }

        try await start(first)
        try await start(second)
        return Fixture(
            managers: [first, second],
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            providerID: first.identity.objectId.string,
            workspaceURI: workspaceURI,
            recorder: WorkspaceFixtureRecorder(),
            registrations: [registration]
        )
    }

    private enum Mutation {
        case attach
        case detach
    }

    private static func registerRawMutation(
        on manager: CommunicationManager,
        mutation: Mutation,
        outcome: MutateOutcome,
        recorder: WorkspaceFixtureRecorder
    ) async throws -> CallHandlerRegistration {
        let operation = mutation == .attach
            ? WorkspaceOpsProvider.attachOperation
            : WorkspaceOpsProvider.detachOperation
        let reasonCode = mutation == .attach ? "workspaceAttachConflict" : "workspaceDetachConflict"
        return try await manager.registerCallHandler(operation: operation) { snapshot in
            if let parameters = snapshot.parameters,
               let request = try? JSONDecoder().decode(WorkspaceOpsRequest.self, from: Data(parameters.utf8)) {
                switch mutation {
                case .attach: await recorder.recordAttach(request)
                case .detach: await recorder.recordDetach(request)
                }
            }
            switch outcome {
            case .accept:
                return .success(result: try Self.encodeMutation(accepted: true))
            case .reject:
                return .success(result: try Self.encodeMutation(accepted: false))
            case .protocolFailure:
                return .failure(
                    code: 409,
                    message: GnosticProtocol.failureMessage(
                        reasonCode: reasonCode,
                        message: "The workspace mutation conflicted.",
                        statusCode: 409
                    )
                )
            }
        }
    }

    private static func registerInvocation(
        workspaceID: UUID,
        outcome: InvokeOutcome,
        on manager: CommunicationManager
    ) async throws -> [CallHandlerRegistration] {
        switch outcome {
        case .echo, .toolFailure:
            let workspace = GnosticWorkspaceProvider(
                workspaceID: workspaceID,
                tools: [
                    GnosticWorkspaceToolDefinition(
                        id: "workspace_echo",
                        name: "Workspace echo",
                        description: "Echoes input."
                    ),
                ]
            ) { toolID, arguments in
                guard toolID == "workspace_echo" else { return .failure("unknown fixture tool") }
                if outcome == .toolFailure { return .failure("boom") }
                return .success(arguments["value"]?.value as? String ?? "")
            }
            return [try await workspace.register(on: manager)]
        case .protocolFailure:
            return [try await manager.registerCallHandler(
                operation: GnosticWorkspaceProvider.invocationOperation
            ) { _ in
                .failure(
                    code: 500,
                    message: GnosticProtocol.failureMessage(
                        reasonCode: "workspaceInvocationFailed",
                        message: "The workspace invocation failed.",
                        statusCode: 500
                    )
                )
            }]
        case .malformedResult:
            return [try await manager.registerCallHandler(
                operation: GnosticWorkspaceProvider.invocationOperation
            ) { _ in
                // The pre-6.1 PositronicKit `success` key: a valid Call result
                // that the pinned `isSuccess` decoder must reject.
                .success(result: #"{"protocolMajor":2,"success":true,"output":"x"}"#)
            }]
        case .timeout:
            return []
        }
    }

    private static func advertiseWorkspace(
        _ workspaceID: UUID,
        uri: String,
        on manager: CommunicationManager
    ) {
        manager.publishAdvertise(GnosticWorkspaceObject(workspace: WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: uri)!,
            location: .runtime,
            tools: [
                .custom(WorkspaceToolDefinition(
                    id: "workspace_echo",
                    name: "Workspace echo",
                    description: "Echoes input."
                )),
            ]
        )))
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
            name: "Workspace Ascendant",
            description: "Offline workspace provider.",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: AscendantBackendCapabilities(interoperability: capabilities)
        )))
        manager.publishAdvertise(GnosticTimelineObject(timeline: AscendantBackendTimeline(
            id: timelineID,
            title: "Workspace Timeline",
            attachedWorkspaceIDs: [],
            attachedAscendantID: ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )))
    }

    private nonisolated static func encodeMutation(accepted: Bool) throws -> String {
        String(decoding: try JSONEncoder().encode(WorkspaceMutationResult(accepted: accepted)), as: UTF8.self)
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

/// Records attach and detach requests observed by the fixture serve.
actor WorkspaceFixtureRecorder {
    private(set) var attachRequests: [WorkspaceOpsRequest] = []
    private(set) var detachRequests: [WorkspaceOpsRequest] = []

    func recordAttach(_ request: WorkspaceOpsRequest) {
        attachRequests.append(request)
    }

    func recordDetach(_ request: WorkspaceOpsRequest) {
        detachRequests.append(request)
    }
}
