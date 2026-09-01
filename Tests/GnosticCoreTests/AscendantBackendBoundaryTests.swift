// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Ascendant backend boundary")
struct AscendantBackendBoundaryTests {
    @Test("a backend-neutral fixture can satisfy the mandatory contract")
    @MainActor
    func fixtureDoesNotNeedPositronicKit() async throws {
        #expect(AscendantBackendServices.empty.workspace == nil)
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000701")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000702")!
        let fixture = try FixtureBackend(
            ascendant: .init(
                id: ascendantID,
                name: "Neutral fixture",
                defaultTimelineID: timelineID,
                kind: "fixture"
            ),
            configuration: .init(kind: "fixture"),
            services: .empty,
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
    )

        #expect(fixture.identity.id == ascendantID)
        #expect(try await fixture.operatedTimelines().map(\.id) == [timelineID])
        let timeline = try await fixture.timeline(id: timelineID)
        #expect(timeline.id == timelineID)
        let result = try await timeline.runTurn(
            .init(message: "hello"),
            updates: NoopBackendUpdateSink()
        )
        #expect(result == "fixture: hello")
        await fixture.shutdown()
        await #expect(throws: AscendantBackendError.lifecycleUnusable(.init(code: "fixtureShutdown", message: "fixture is shut down"))) {
            _ = try await timeline.runTurn(.init(message: "after shutdown"), updates: NoopBackendUpdateSink())
        }
    }

    @Test("a Timeline session identity mismatch is a quarantined contract violation")
    @MainActor
    func mismatchedTimelineSessionIsRejected() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000703")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000704")!
        let returnedID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000705")!
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "mismatched-fixture") { ascendant, configuration, services, timelines in
            try FixtureBackend(
                ascendant: ascendant,
                configuration: configuration,
                services: services,
                timelines: timelines,
                returnedSessionID: returnedID
            )
        }
        let runtime = try await NodeRuntime(
            plan: NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "mismatched-session-\(UUID().uuidString.lowercased())"),
                node: .init(id: UUID()),
                ascendants: [.init(id: ascendantID, name: "Mismatched fixture", defaultTimelineID: timelineID, kind: "mismatched-fixture")],
                timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: adapters
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        do {
            _ = try await runtime.turn(.init(message: "contract", timelineID: timelineID, clientTurnID: "contract"))
            Issue.record("The provider accepted a Timeline session with the wrong identity.")
        } catch let error as AscendantTurnError {
            #expect(error == .terminal(
                timelineID: timelineID,
                clientTurnID: "contract",
                code: "backendContractViolation",
                detail: "Backend returned Timeline \(returnedID.uuidString) for requested Timeline \(timelineID.uuidString).",
                retryable: false
            ))
        }
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
    }

    @Test("Workspace intent remains distinct from effective availability")
    func workspaceAttachmentProjectionPreservesIntent() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000711")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000712")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000713")!
        let plan = try NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "backend-boundary"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000714")!),
            ascendants: [.init(id: ascendantID, name: "Neutral", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID, attachments: [.network(workspaceID, uri: "workspace://remote")])]
        ).compileLaunchPlan()
        let now = Date(timeIntervalSince1970: 1)
        let operated = AscendantBackendTimeline(
            id: timelineID,
            title: "Default",
            attachedWorkspaceIDs: [workspaceID],
            ascendantID: ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )
        let registry = try NodeRegistry(plan: plan, operatedTimelines: [operated])

        #expect(await registry.effectiveWorkspaceStatus(id: workspaceID) == .unavailable)
        #expect(await registry.attachmentIntent(for: timelineID) == [.network(workspaceID, uri: "workspace://remote")])
        #expect(await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported))
        #expect(await registry.effectiveWorkspaceStatus(id: workspaceID) == .unsupported)
        #expect(await registry.attachmentIntent(for: timelineID) == [.network(workspaceID, uri: "workspace://remote")])
        #expect(await registry.setWorkspaceStatus(id: workspaceID, status: .available))
        #expect(await registry.effectiveWorkspaceStatus(id: workspaceID) == .available)
        #expect(await registry.attachmentIntent(for: timelineID) == [.network(workspaceID, uri: "workspace://remote")])
    }
}

@MainActor
private final class FixtureBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    private var timeline: AscendantBackendTimeline
    private var isShutdown = false
    private let returnedSessionID: UUID?

    init(
        ascendant: NodeManifest.Ascendant,
        configuration: AscendantBackendConfiguration,
        services _: AscendantBackendServices,
        timelines: [NodeManifest.Timeline],
        returnedSessionID: UUID? = nil
    ) throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        guard let timeline = timelines.first(where: { $0.id == ascendant.defaultTimelineID }) else {
            throw AscendantBackendError.invalidConfiguration("missing default Timeline")
        }
        let now = Date()
        identity = .init(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now
        )
        self.timeline = .init(
            id: timeline.id,
            title: timeline.title,
            attachedWorkspaceIDs: timeline.attachments.map(\.workspaceID),
            ascendantID: ascendant.id,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )
        self.returnedSessionID = returnedSessionID
    }

    func validateConfiguration() throws {}

    func operatedTimelines() async throws -> [AscendantBackendTimeline] { [timeline] }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        timeline = .init(id: id, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        return timeline
    }

    func removeTimeline(id _: UUID) async {}

    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard timeline.id == id else { throw AscendantBackendError.timelineNotFound(id) }
        timeline = .init(id: timeline.id, title: title, attachedWorkspaceIDs: timeline.attachedWorkspaceIDs, ascendantID: identity.id, isArchived: timeline.isArchived, isPrivate: timeline.isPrivate, createdAt: timeline.createdAt, updatedAt: Date())
        return timeline
    }

    func timeline(id: UUID) async throws -> any AscendantBackendTimelineSession {
        guard timeline.id == id else { throw AscendantBackendError.timelineNotFound(id) }
        return TimelineSession(id: returnedSessionID ?? id, backend: self)
    }

    private func runTurn(_ request: AscendantBackendTimelineTurnRequest) throws -> String {
        guard !isShutdown else {
            throw AscendantBackendError.lifecycleUnusable(.init(code: "fixtureShutdown", message: "fixture is shut down"))
        }
        return "fixture: \(request.message)"
    }

    @MainActor
    private final class TimelineSession: AscendantBackendTimelineSession {
        let id: UUID
        private let backend: FixtureBackend

        init(id: UUID, backend: FixtureBackend) {
            self.id = id
            self.backend = backend
        }

        func runTurn(
            _ request: AscendantBackendTimelineTurnRequest,
            updates _: any AscendantBackendUpdateSink
        ) async throws -> String {
            try backend.runTurn(request)
        }
    }

    func cancel() async {}
    func shutdown() async { isShutdown = true }
}

private struct NoopBackendUpdateSink: AscendantBackendUpdateSink {
    func append(_ update: AscendantBackendUpdate) async {}
}
