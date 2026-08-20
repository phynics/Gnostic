// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit
import Testing
@testable import GnosticCore

@Suite("Node transport boundary")
struct NodeTransportTests {
    @Test("the transport invokes its inward operation boundary without a NodeRuntime")
    @MainActor
    func invokesInwardOperationBoundary() async throws {
        var handled = false
        let transport = NodeTransport(
            isAvailable: { true },
            chat: { request in
                handled = true
                return .init(text: "handled: \(request.message)")
            },
            timelineStatus: { _ in fatalError("not used") },
            selectAscendant: { _ in fatalError("not used") },
            createTimeline: { _, _ in fatalError("not used") },
            listTimelines: { fatalError("not used") },
            renameTimeline: { _ in fatalError("not used") },
            listWorkspaces: { [] },
            attachWorkspace: { _ in fatalError("not used") },
            detachWorkspace: { _ in fatalError("not used") }
        )

        let result = try await transport.chat(.init(message: "hello", timelineID: UUID()))

        #expect(result.text == "handled: hello")
        #expect(handled)
    }

    @Test("chat and timeline services run against an adapter stub without transport")
    @MainActor
    func servicesUseAdapterBoundaryWithoutBroker() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000001")!
        let timelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000002")!
        let plan = try NodeManifest(
            broker: .init(host: "unused", port: 1883, namespace: "service-unit"),
            node: .init(id: UUID(uuidString: "13100000-0000-4000-8000-000000000003")!),
            ascendants: [.init(id: ascendantID, name: "Stub", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Before", operatingAscendantID: ascendantID)]
        ).compileLaunchPlan()
        let adapter = ServiceStubAscendantAdapter(ascendantID: ascendantID, timelineID: timelineID)
        let registry = try NodeRegistry(plan: plan, operatedTimelines: try await adapter.timelines())
        let backend = LegacyAscendantBackendBridge(adapter: adapter)
        let timelineService = TimelineService(
            ascendantIDs: [ascendantID],
            registry: registry,
            isClosed: { false },
            adapter: { $0 == ascendantID ? backend : nil },
            advertise: { _, _ in }
        )
        let chatService = ChatTurnService(
            registry: registry,
            coordinator: AscendantTurnCoordinator(),
            updates: AscendantTurnUpdateStore(),
            isRunning: { true },
            adapter: { $0 == ascendantID ? backend : nil }
        )

        let renamed = try await timelineService.rename(.init(timelineID: timelineID, title: "After"))
        let reply = try await chatService.chat(.init(message: "hello", timelineID: timelineID))

        #expect(renamed.title == "After")
        #expect(reply.text == "stub: hello")
        #expect(try timelineService.selectAscendant(requested: nil) == ascendantID)
    }

    @Test("workspace service lists remote workspaces through a discovery stub")
    @MainActor
    func workspaceServiceUsesDiscoveryBoundaryWithoutBroker() async throws {
        let workspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000004")!
        let discovery = ServiceStubWorkspaceDiscovery(
            entry: .init(
                objectID: workspaceID,
                objectType: GnosticObjectType.workspace,
                providerID: "stub-provider",
                name: "Remote stub",
                knownProperties: [:],
                dynamicProperties: [:],
                workspace: .init(id: workspaceID, uri: "gnostic://workspace/remote", isAvailable: true, tools: [])
            ),
            status: .available(providerID: "stub-provider", uri: "gnostic://workspace/remote")
        )
        let plan = try NodeManifest.empty(
            broker: .init(host: "unused", port: 1883, namespace: "workspace-service-unit")
        ).compileLaunchPlan()
        let service = WorkspaceService(
            plan: plan,
            registry: try NodeRegistry(plan: plan, operatedTimelines: []),
            discovery: discovery,
            localWorkspaces: [:],
            references: [:],
            isRunning: { true },
            adapter: { _ in nil },
            readvertiseTimeline: { _ in }
        )

        let listings = await service.listAttachable()

        #expect(listings.map(\.id) == [workspaceID])
        #expect(listings.first?.name == "Remote stub")
    }
}

@MainActor
private final class ServiceStubWorkspaceDiscovery: WorkspaceDiscovery {
    private let entry: NetworkCatalogEntry
    private let status: WorkspaceAttachmentStatus

    init(entry: NetworkCatalogEntry, status: WorkspaceAttachmentStatus) {
        self.entry = entry
        self.status = status
    }

    func discover(timeout _: Duration) async {}
    func objects() async -> [NetworkCatalogEntry] { [entry] }
    func attachmentStatus(id _: UUID) async -> WorkspaceAttachmentStatus { status }
}

@MainActor
private final class ServiceStubAscendantAdapter: AscendantRuntimeAdapter {
    let identity: AscendantRuntimeIdentity
    private var storedTimelines: [AscendantRuntimeTimeline]

    init(ascendantID: UUID, timelineID: UUID) {
        let now = Date()
        identity = .init(
            id: ascendantID,
            name: "Stub",
            description: "",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now
        )
        storedTimelines = [.init(
            id: timelineID,
            title: "Before",
            attachedWorkspaceIDs: [],
            attachedAgentInstanceID: ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )]
    }

    func timelines() async throws -> [AscendantRuntimeTimeline] { storedTimelines }
    func createTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline {
        let now = Date()
        let timeline = AscendantRuntimeTimeline(id: id, title: title, attachedWorkspaceIDs: [], attachedAgentInstanceID: identity.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        storedTimelines.append(timeline)
        return timeline
    }
    func removeTimeline(id: UUID) async { storedTimelines.removeAll { $0.id == id } }
    func renameTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline {
        guard let index = storedTimelines.firstIndex(where: { $0.id == id }) else { throw NodeRuntimeError.missingTimeline(id) }
        let old = storedTimelines[index]
        let renamed = AscendantRuntimeTimeline(id: id, title: title, attachedWorkspaceIDs: old.attachedWorkspaceIDs, attachedAgentInstanceID: old.attachedAgentInstanceID, isArchived: old.isArchived, isPrivate: old.isPrivate, createdAt: old.createdAt, updatedAt: Date())
        storedTimelines[index] = renamed
        return renamed
    }
    func attachWorkspace(_: WorkspaceReference, to _: UUID) async throws {}
    func detachWorkspace(_: UUID, from _: UUID) async throws {}
    func enabledToolIDs(for _: UUID) async -> [String] { [] }
    func runTurn(_ request: AgentChatRequest, updates _: AscendantTurnUpdateStore) async throws -> String { "stub: \(request.message)" }
    func cancelAll() async {}
    func shutdown() async {}
}
