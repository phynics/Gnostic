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
    struct Fixture {
        let manager: CommunicationManager
        let workspaceID: UUID
        let timelineID: UUID
        let ascendantID: UUID
        let providerID: String
        let workspaceURI: String
        let recorder: WorkspaceFixtureRecorder
        let registrations: [CallHandlerRegistration]
    }

    static func makeFixture(
        namespace: String,
        host: String,
        port: Int
    ) async throws -> Fixture {
        let manager = try CommunicationManager(
            identity: Identity(name: "gnostic-workspace-client-provider"),
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

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let workspaceID = UUID()
        let timelineID = UUID()
        let ascendantID = UUID()
        let workspaceURI = "workspace://fixture"

        manager.publishAdvertise(GnosticWorkspaceObject(workspace: WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: workspaceURI)!,
            location: .runtime,
            tools: [
                .custom(WorkspaceToolDefinition(
                    id: "workspace_echo",
                    name: "Workspace echo",
                    description: "Echoes input."
                )),
            ]
        )))
        manager.publishAdvertise(GnosticAscendantObject(identity: AscendantBackendIdentity(
            id: ascendantID,
            name: "Workspace Ascendant",
            description: "Offline workspace provider.",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: AscendantBackendCapabilities(interoperability: [
                GnosticCapability.textTurnInput,
                GnosticCapability.workspaceAttachment,
                GnosticCapability.workspaceToolInvocation,
            ])
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

        let recorder = WorkspaceFixtureRecorder()
        var registrations: [CallHandlerRegistration] = []
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
            return .success(arguments["value"]?.value as? String ?? "")
        }
        registrations.append(try await workspace.register(on: manager))

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
        registrations.append(contentsOf: try await operations.register(on: manager))

        try await start(manager)
        return Fixture(
            manager: manager,
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            providerID: manager.identity.objectId.string,
            workspaceURI: workspaceURI,
            recorder: recorder,
            registrations: registrations
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
