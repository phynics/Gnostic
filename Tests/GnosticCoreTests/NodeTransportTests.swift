// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts
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
            turn: { request in
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

        let result = try await transport.turn(.init(message: "hello", timelineID: UUID()))

        #expect(result.text == "handled: hello")
        #expect(handled)
    }

    @Test("turn and timeline services run against an adapter stub without transport")
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
        let adapter = ServiceStubAscendantBackend(ascendantID: ascendantID, timelineID: timelineID)
        let registry = try NodeRegistry(plan: plan, operatedTimelines: try await adapter.operatedTimelines())
        let backend = adapter
        let timelineService = TimelineService(
            ascendantIDs: [ascendantID],
            registry: registry,
            isClosed: { false },
            adapter: { $0 == ascendantID ? backend : nil },
            advertise: { _, _ in }
        )
        let turnService = TurnService(
            registry: registry,
            coordinator: AscendantTurnCoordinator(),
            updates: AscendantTurnUpdateStore(),
            isRunning: { true },
            backend: { id in
                guard id == ascendantID else { throw NodeRuntimeError.unknownAscendant(id) }
                return backend
            }
        )

        let renamed = try await timelineService.rename(.init(timelineID: timelineID, title: "After"))
        let reply = try await turnService.turn(.init(message: "hello", timelineID: timelineID))

        #expect(renamed.title == "After")
        #expect(reply.text == "stub: hello")
        #expect(adapter.timelineSessionRequests == 1)
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
                protocolMajor: GnosticProtocol.currentMajor,
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
        #expect(listings.first?.status == .available)
    }

    @Test("workspace listing rejects incompatible discovery entries")
    @MainActor
    func workspaceListingRejectsIncompatibleDiscoveryEntries() async throws {
        let workspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000014")!
        let discovery = ServiceStubWorkspaceDiscovery(
            entry: .init(
                objectID: workspaceID,
                objectType: GnosticObjectType.workspace,
                protocolMajor: 99,
                providerID: "future-provider",
                name: "Future workspace",
                knownProperties: [:],
                dynamicProperties: [:],
                workspace: .init(id: workspaceID, uri: "gnostic://workspace/future", isAvailable: true, tools: [])
            ),
            status: .available(providerID: "future-provider", uri: "gnostic://workspace/future")
        )
        let plan = try NodeManifest.empty(
            broker: .init(host: "unused", port: 1883, namespace: "workspace-incompatible-unit")
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

        #expect(await service.listAttachable().isEmpty)
    }

    @Test("local Workspace operations revalidate effective status")
    @MainActor
    func localWorkspaceOperationsRevalidateEffectiveStatus() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000010")!
        let timelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000011")!
        let workspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000012")!
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "echo://local")!,
            location: .runtime,
            tools: EchoWorkspace.toolDefinitions
        )
        let plan = try NodeManifest(
            broker: .init(host: "unused", port: 1883, namespace: "workspace-status-unit"),
            node: .init(id: UUID(uuidString: "13100000-0000-4000-8000-000000000013")!),
            ascendants: [.init(id: ascendantID, name: "Stub", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)],
            workspaces: [.init(id: workspaceID, name: "Local", uri: "echo://local", kind: "echo")]
        ).compileLaunchPlan()
        let adapter = ServiceStubAscendantBackend(ascendantID: ascendantID, timelineID: timelineID)
        let registry = try NodeRegistry(plan: plan, operatedTimelines: try await adapter.operatedTimelines())
        let service = WorkspaceService(
            plan: plan,
            registry: registry,
            discovery: ServiceStubWorkspaceDiscovery(
                entry: .init(
                    objectID: workspaceID,
                    objectType: GnosticObjectType.workspace,
                    protocolMajor: GnosticProtocol.currentMajor,
                    providerID: "stub-provider",
                    name: "Local",
                    knownProperties: [:],
                    dynamicProperties: [:],
                    workspace: .init(id: workspaceID, uri: "echo://local", isAvailable: true, tools: [])
                ),
                status: .available(providerID: "stub-provider", uri: "echo://local")
            ),
            localWorkspaces: [workspaceID: EchoWorkspace(reference: reference)],
            references: [workspaceID: reference],
            isRunning: { true },
            adapter: { $0 == ascendantID ? adapter : nil },
            readvertiseTimeline: { _ in }
        )

        await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)

        await #expect(throws: DiscoveredWorkspaceAttachmentError.unavailable(.unsupported)) {
            _ = try await service.executeLocalTool(workspaceID: workspaceID, toolID: EchoWorkspace.toolID, arguments: [:])
        }
        await #expect(throws: DiscoveredWorkspaceAttachmentError.unavailable(.unsupported)) {
            _ = try await service.attach(.init(workspaceID: workspaceID, timelineID: timelineID))
        }
    }

    @Test("dynamic Workspace attachments are restored after loss and rediscovery")
    @MainActor
    func dynamicWorkspaceAttachmentSurvivesRediscovery() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000006")!
        let timelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000007")!
        let workspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000008")!
        let uri = "gnostic://workspace/dynamic"
        let discovery = MutableServiceStubWorkspaceDiscovery(
            entry: .init(
                objectID: workspaceID,
                objectType: GnosticObjectType.workspace,
                providerID: "stub-provider",
                name: "Dynamic remote",
                knownProperties: [:],
                dynamicProperties: [:],
                workspace: .init(id: workspaceID, uri: uri, isAvailable: true, tools: [])
            )
        )
        let adapter = ServiceStubAscendantBackend(ascendantID: ascendantID, timelineID: timelineID)
        let plan = try NodeManifest(
            broker: .init(host: "unused", port: 1883, namespace: "workspace-service-dynamic-attachment"),
            node: .init(id: UUID(uuidString: "13100000-0000-4000-8000-000000000009")!),
            ascendants: [.init(id: ascendantID, name: "Stub", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Dynamic", operatingAscendantID: ascendantID)]
        ).compileLaunchPlan()
        let registry = try NodeRegistry(plan: plan, operatedTimelines: try await adapter.operatedTimelines())
        let backend = adapter
        let service = WorkspaceService(
            plan: plan,
            registry: registry,
            discovery: discovery,
            localWorkspaces: [:],
            references: [:],
            isRunning: { true },
            adapter: { $0 == ascendantID ? backend : nil },
            readvertiseTimeline: { _ in }
        )

        _ = try await service.attach(.init(workspaceID: workspaceID, timelineID: timelineID))
        #expect(await registry.attachmentIntent(for: timelineID) == [.network(workspaceID, uri: uri)])
        #expect(try await adapter.operatedTimelines().first?.attachedWorkspaceIDs == [workspaceID])

        try await adapter.detachWorkspace(workspaceID, from: timelineID)
        discovery.isAvailable = false
        await registry.setWorkspaceStatus(id: workspaceID, status: .unavailable)
        await service.refreshUnresolved()
        #expect(try await adapter.operatedTimelines().first?.attachedWorkspaceIDs.isEmpty == true)

        discovery.isAvailable = true
        await service.refreshUnresolved()

        #expect(try await adapter.operatedTimelines().first?.attachedWorkspaceIDs == [workspaceID])
        #expect(await registry.attachmentIntent(for: timelineID) == [.network(workspaceID, uri: uri)])
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
    func queryTools(workspaceID _: UUID, timeout _: Duration) async {}
    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor? {
        guard providerID == entry.providerID, workspaceID == entry.workspace?.id else { return nil }
        return entry.workspace
    }
}

@MainActor
private final class MutableServiceStubWorkspaceDiscovery: WorkspaceDiscovery {
    let entry: NetworkCatalogEntry
    var isAvailable = true

    init(entry: NetworkCatalogEntry) {
        self.entry = entry
    }

    func discover(timeout _: Duration) async {}
    func objects() async -> [NetworkCatalogEntry] { [entry] }
    func attachmentStatus(id _: UUID) async -> WorkspaceAttachmentStatus {
        isAvailable
            ? .available(providerID: entry.providerID, uri: entry.workspace?.uri ?? "")
            : .unavailable
    }
    func queryTools(workspaceID _: UUID, timeout _: Duration) async {}
    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor? {
        guard providerID == entry.providerID, workspaceID == entry.workspace?.id else { return nil }
        return entry.workspace
    }
}

@MainActor
private final class ServiceStubAscendantBackend: AscendantBackend, AscendantBackendWorkspaceCapability {
    let identity: AscendantBackendIdentity
    private var storedTimelines: [AscendantBackendTimeline]
    private(set) var timelineSessionRequests = 0

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
            ascendantID: ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )]
    }

    func validateConfiguration() throws {}
    func operatedTimelines() async throws -> [AscendantBackendTimeline] { storedTimelines }
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        let timeline = AscendantBackendTimeline(id: id, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        storedTimelines.append(timeline)
        return timeline
    }
    func removeTimeline(id: UUID) async { storedTimelines.removeAll { $0.id == id } }
    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let index = storedTimelines.firstIndex(where: { $0.id == id }) else { throw NodeRuntimeError.missingTimeline(id) }
        let old = storedTimelines[index]
        let renamed = AscendantBackendTimeline(id: id, title: title, attachedWorkspaceIDs: old.attachedWorkspaceIDs, ascendantID: old.ascendantID, isArchived: old.isArchived, isPrivate: old.isPrivate, createdAt: old.createdAt, updatedAt: Date())
        storedTimelines[index] = renamed
        return renamed
    }
    func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {
        guard let index = storedTimelines.firstIndex(where: { $0.id == timelineID }) else {
            throw NodeRuntimeError.missingTimeline(timelineID)
        }
        let old = storedTimelines[index]
        let attached = old.attachedWorkspaceIDs + (old.attachedWorkspaceIDs.contains(reference.id) ? [] : [reference.id])
        storedTimelines[index] = AscendantBackendTimeline(
            id: old.id,
            title: old.title,
            attachedWorkspaceIDs: attached,
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }
    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        guard let index = storedTimelines.firstIndex(where: { $0.id == timelineID }) else {
            throw NodeRuntimeError.missingTimeline(timelineID)
        }
        let old = storedTimelines[index]
        storedTimelines[index] = AscendantBackendTimeline(
            id: old.id,
            title: old.title,
            attachedWorkspaceIDs: old.attachedWorkspaceIDs.filter { $0 != workspaceID },
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }
    func enabledToolIDs(for _: UUID) async -> [String] { [] }
    func timeline(id: UUID) async throws -> any AscendantBackendTimelineSession {
        guard storedTimelines.contains(where: { $0.id == id }) else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        timelineSessionRequests += 1
        return ServiceStubTimelineSession(id: id)
    }
    func cancel() async {}
    func shutdown() async {}
}

@MainActor
private final class ServiceStubTimelineSession: AscendantBackendTimelineSession {
    let id: UUID

    init(id: UUID) {
        self.id = id
    }

    func runTurn(
        _ request: AscendantBackendTimelineTurnRequest,
        updates _: any AscendantBackendUpdateSink
    ) async throws -> String {
        "stub: \(request.message)"
    }
}
