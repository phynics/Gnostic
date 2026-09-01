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
        let lease = UUID()
        let initialProjectionRequestCount = adapter.operatedTimelinesRequests
        await registry.activateBackendLease(lease, for: ascendantID)
        let provider = ClosureBackendSessionProvider(
            isRunning: { true },
            lifecycleGeneration: { 0 },
            adapter: { $0 == ascendantID ? backend : nil },
            current: { id, candidate, generation in
                id == ascendantID
                    && generation == 0
                    && (candidate as AnyObject) === (backend as AnyObject)
            },
            backendLease: { id, candidate in
                id == ascendantID && (candidate as AnyObject) === (backend as AnyObject) ? lease : nil
            },
            failure: { _, _, _ in },
            backend: { id in
                guard id == ascendantID else { throw NodeRuntimeError.unknownAscendant(id) }
                return backend
            }
        )
        let timelineService = TimelineService(
            ascendantIDs: [ascendantID],
            registry: registry,
            backendProvider: provider,
            advertise: { _, _ in }
        )
        let turnService = TurnService(
            registry: registry,
            coordinator: AscendantTurnCoordinator(),
            updates: AscendantTurnUpdateStore(),
            backendProvider: provider
        )

        let renamed = try await timelineService.rename(.init(timelineID: timelineID, title: "After"))
        let reply = try await turnService.turn(.init(message: "hello", timelineID: timelineID))

        #expect(renamed.title == "After")
        #expect(reply.text == "stub: hello")
        #expect(adapter.timelineSessionRequests == 2)
        #expect(adapter.operatedTimelinesRequests == initialProjectionRequestCount)
        #expect(try timelineService.selectAscendant(requested: nil) == ascendantID)
    }

    @Test("rename compensation uses the original Timeline session and preserves the registry error")
    @MainActor
    func renameCompensatesThroughOriginalSession() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000011")!
        let timelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000012")!
        let plan = try NodeManifest(
            broker: .init(host: "unused", port: 1883, namespace: "rename-compensation"),
            node: .init(id: UUID(uuidString: "13100000-0000-4000-8000-000000000013")!),
            ascendants: [.init(id: ascendantID, name: "Stub", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Before", operatingAscendantID: ascendantID)]
        ).compileLaunchPlan()
        let adapter = ServiceStubAscendantBackend(ascendantID: ascendantID, timelineID: timelineID)
        let registry = try NodeRegistry(plan: plan, operatedTimelines: try await adapter.operatedTimelines())
        let providerLease = UUID()
        await registry.activateBackendLease(UUID(), for: ascendantID)
        let provider = ClosureBackendSessionProvider(
            isRunning: { true },
            lifecycleGeneration: { 0 },
            adapter: { $0 == ascendantID ? adapter : nil },
            current: { id, candidate, generation in
                id == ascendantID
                    && generation == 0
                    && (candidate as AnyObject) === (adapter as AnyObject)
            },
            backendLease: { id, candidate in
                id == ascendantID && (candidate as AnyObject) === (adapter as AnyObject) ? providerLease : nil
            },
            failure: { _, _, _ in },
            backend: { _ in adapter }
        )
        let timelineService = TimelineService(
            ascendantIDs: [ascendantID],
            registry: registry,
            backendProvider: provider,
            advertise: { _, _ in }
        )

        do {
            _ = try await timelineService.rename(.init(timelineID: timelineID, title: "Rejected"))
            Issue.record("The registry rejection unexpectedly succeeded.")
        } catch let error as NodeRuntimeError {
            #expect(error == .notRunning)
        }

        #expect(try await adapter.operatedTimelines().first?.title == "Before")
        #expect(await registry.timeline(id: timelineID)?.timeline.title == "Before")
        #expect(adapter.timelineSessionRequests == 1)
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
        let lease = UUID.makeVersion4()
        let registry = try NodeRegistry(
            plan: plan,
            operatedTimelines: try await adapter.operatedTimelines(),
            backendLeases: [ascendantID: lease]
        )
        let initialOperatedTimelinesRequests = adapter.operatedTimelinesRequests
        let backend = adapter
        let service = WorkspaceService(
            plan: plan,
            registry: registry,
            discovery: discovery,
            localWorkspaces: [:],
            references: [:],
            isRunning: { true },
            backendLease: { id, candidate in
                id == ascendantID && (candidate as AnyObject) === (backend as AnyObject) ? lease : nil
            },
            adapter: { $0 == ascendantID ? backend : nil },
            readvertiseTimeline: { _ in }
        )

        _ = try await service.attach(.init(workspaceID: workspaceID, timelineID: timelineID))
        #expect(await registry.attachmentIntent(for: timelineID) == [.network(workspaceID, uri: uri)])
        #expect(adapter.storedTimelines.first?.attachedWorkspaceIDs == [workspaceID])
        #expect(try await service.enabledToolIDs(for: timelineID).isEmpty)

        let timeline = try await adapter.timeline(id: timelineID)
        let workspaceSession = try #require(timeline as? any AscendantBackendTimelineWorkspaceSession)
        let detachedProjection = try await workspaceSession.detachWorkspace(id: workspaceID)
        #expect(detachedProjection.id == timelineID)
        #expect(detachedProjection.attachedWorkspaceIDs.isEmpty)
        discovery.isAvailable = false
        await registry.setWorkspaceStatus(id: workspaceID, status: .unavailable)
        await service.refreshUnresolved()
        #expect(adapter.storedTimelines.first?.attachedWorkspaceIDs.isEmpty == true)

        discovery.isAvailable = true
        await service.refreshUnresolved()

        #expect(adapter.storedTimelines.first?.attachedWorkspaceIDs == [workspaceID])
        #expect(await registry.attachmentIntent(for: timelineID) == [.network(workspaceID, uri: uri)])
        #expect(adapter.operatedTimelinesRequests == initialOperatedTimelinesRequests)
    }

    @Test("a leased Workspace Timeline session rejects a mismatched projection")
    @MainActor
    func mismatchedWorkspaceProjectionIsRejected() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-0000-8000-000000000021")!
        let timelineID = UUID(uuidString: "13100000-0000-0000-8000-000000000022")!
        let returnedID = UUID(uuidString: "13100000-0000-0000-8000-000000000023")!
        let workspaceID = UUID(uuidString: "13100000-0000-0000-8000-000000000024")!
        let backend = ServiceStubAscendantBackend(
            ascendantID: ascendantID,
            timelineID: timelineID,
            returnedWorkspaceProjectionID: returnedID
        )
        let lease = UUID.makeVersion4()
        var failureCount = 0
        let provider = ClosureBackendSessionProvider(
            isRunning: { true },
            lifecycleGeneration: { 0 },
            adapter: { $0 == ascendantID ? backend : nil },
            current: { id, candidate, generation in
                id == ascendantID
                    && generation == 0
                    && (candidate as AnyObject) === (backend as AnyObject)
            },
            backendLease: { id, candidate in
                id == ascendantID && (candidate as AnyObject) === (backend as AnyObject) ? lease : nil
            },
            failure: { _, _, _ in failureCount += 1 },
            backend: { _ in backend }
        )
        let native = try await backend.timeline(id: timelineID)
        let leased = LeasedBackendTimelineSession(
            id: timelineID,
            context: .init(ascendantID: ascendantID, lease: lease, generation: 0),
            timeline: native,
            provider: provider
        )
        let workspace = try #require(leased.workspace)

        await #expect(throws: AscendantBackendError.contractViolation(
            .projectionTimelineMismatch(expected: timelineID, actual: returnedID)
        )) {
            _ = try await workspace.attachWorkspace(.init(
                id: workspaceID,
                uri: "workspace://test",
                status: .available
            ))
        }
        #expect(failureCount == 1)
    }

    @Test("Workspace mutation and registry commit remain serialized per Timeline")
    @MainActor
    func workspaceMutationAndCommitAreSerializedPerTimeline() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000031")!
        let timelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000032")!
        let firstWorkspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000033")!
        let secondWorkspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000034")!
        let firstReference = WorkspaceReference(
            id: firstWorkspaceID,
            uri: WorkspaceURI(parsing: "workspace://first")!,
            location: .runtime
        )
        let secondReference = WorkspaceReference(
            id: secondWorkspaceID,
            uri: WorkspaceURI(parsing: "workspace://second")!,
            location: .runtime
        )
        let control = ServiceStubAttachControl(firstWorkspaceID: firstWorkspaceID)
        let backend = ServiceStubAscendantBackend(
            ascendantID: ascendantID,
            timelineID: timelineID,
            attachControl: control
        )
        let plan = try NodeManifest(
            broker: .init(host: "unused", port: 1883, namespace: "workspace-operation-order"),
            node: .init(id: UUID(uuidString: "13100000-0000-4000-8000-000000000035")!),
            ascendants: [.init(id: ascendantID, name: "Stub", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Timeline", operatingAscendantID: ascendantID)],
            workspaces: [
                .init(id: firstWorkspaceID, name: "First", uri: firstReference.uri.description, kind: "echo"),
                .init(id: secondWorkspaceID, name: "Second", uri: secondReference.uri.description, kind: "echo"),
            ]
        ).compileLaunchPlan()
        let registry = try NodeRegistry(plan: plan, operatedTimelines: try await backend.operatedTimelines())
        let lease = UUID.makeVersion4()
        await registry.activateBackendLease(lease, for: ascendantID)
        let service = WorkspaceService(
            plan: plan,
            registry: registry,
            discovery: ServiceStubWorkspaceDiscovery(
                entry: .init(
                    objectID: firstWorkspaceID,
                    objectType: GnosticObjectType.workspace,
                    protocolMajor: GnosticProtocol.currentMajor,
                    providerID: "unused",
                    name: "unused",
                    knownProperties: [:],
                    dynamicProperties: [:],
                    workspace: .init(id: firstWorkspaceID, uri: firstReference.uri.description, isAvailable: true, tools: [])
                ),
                status: .unavailable
            ),
            localWorkspaces: [
                firstWorkspaceID: EchoWorkspace(reference: firstReference),
                secondWorkspaceID: EchoWorkspace(reference: secondReference),
            ],
            references: [firstWorkspaceID: firstReference, secondWorkspaceID: secondReference],
            isRunning: { true },
            lifecycleGeneration: { 0 },
            isCurrentBackend: { id, candidate, generation in
                id == ascendantID && generation == 0 && (candidate as AnyObject) === (backend as AnyObject)
            },
            backendLease: { id, candidate in
                id == ascendantID && (candidate as AnyObject) === (backend as AnyObject) ? lease : nil
            },
            adapter: { $0 == ascendantID ? backend : nil },
            readvertiseTimeline: { _ in }
        )

        let first = Task { try await service.attach(.init(workspaceID: firstWorkspaceID, timelineID: timelineID)) }
        await control.waitForFirstMutation()
        let second = Task { try await service.attach(.init(workspaceID: secondWorkspaceID, timelineID: timelineID)) }
        await Task.yield()
        #expect(backend.attachCalls == [firstWorkspaceID])

        await control.releaseFirstMutation()
        _ = try await first.value
        _ = try await second.value

        #expect(backend.attachCalls == [firstWorkspaceID, secondWorkspaceID])
        #expect(backend.storedTimelines.first?.attachedWorkspaceIDs == [firstWorkspaceID, secondWorkspaceID])
        #expect(await registry.timeline(id: timelineID)?.timeline.attachedWorkspaceIDs == [firstWorkspaceID, secondWorkspaceID])
    }

    @Test("lazy Workspace rehydration restores existing provider references after a later target fails")
    @MainActor
    func lazyWorkspaceRehydrationRestoresExistingReferencesAfterFailure() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000041")!
        let firstTimelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000042")!
        let secondTimelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000043")!
        let workspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000044")!
        let uri = "gnostic://workspace/rehydrate"
        let oldReference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: uri)!,
            location: .attached
        )
        let oldBackendReference = BackendWorkspaceReference(reference: oldReference, status: .unavailable)
        let backend = ServiceStubAscendantBackend(
            ascendantID: ascendantID,
            timelineID: firstTimelineID,
            additionalTimelineIDs: [secondTimelineID],
            initialAttachedWorkspaceIDs: [workspaceID],
            initialWorkspaceReferences: [workspaceID: oldBackendReference],
            attachFailureTimelineID: secondTimelineID
        )
        let newTool = GnosticWorkspaceTool(definition: .init(
            id: "rehydrated_tool",
            name: "Rehydrated tool",
            description: "A newly discovered tool."
        ))
        let discovery = MutableServiceStubWorkspaceDiscovery(
            entry: .init(
                objectID: workspaceID,
                objectType: GnosticObjectType.workspace,
                providerID: "rehydration-provider",
                name: "Rehydrated workspace",
                knownProperties: [:],
                dynamicProperties: [:],
                workspace: .init(id: workspaceID, uri: uri, isAvailable: true, tools: [newTool])
            )
        )
        let plan = try NodeManifest(
            broker: .init(host: "unused", port: 1883, namespace: "workspace-rehydrate-rollback"),
            node: .init(id: UUID(uuidString: "13100000-0000-4000-8000-000000000045")!),
            ascendants: [.init(id: ascendantID, name: "Stub", defaultTimelineID: firstTimelineID)],
            timelines: [
                .init(id: firstTimelineID, title: "First", operatingAscendantID: ascendantID, attachments: [.network(workspaceID, uri: uri)]),
                .init(id: secondTimelineID, title: "Second", operatingAscendantID: ascendantID, attachments: [.network(workspaceID, uri: uri)]),
            ]
        ).compileLaunchPlan()
        let lease = UUID.makeVersion4()
        let registry = try NodeRegistry(
            plan: plan,
            operatedTimelines: try await backend.operatedTimelines(),
            backendLeases: [ascendantID: lease]
        )
        let service = WorkspaceService(
            plan: plan,
            registry: registry,
            discovery: discovery,
            localWorkspaces: [:],
            references: [workspaceID: oldReference],
            isRunning: { true },
            lifecycleGeneration: { 0 },
            isCurrentBackend: { id, candidate, generation in
                id == ascendantID && generation == 0 && (candidate as AnyObject) === (backend as AnyObject)
            },
            backendLease: { id, candidate in
                id == ascendantID && (candidate as AnyObject) === (backend as AnyObject) ? lease : nil
            },
            adapter: { $0 == ascendantID ? backend : nil },
            readvertiseTimeline: { _ in }
        )

        await #expect(throws: ServiceStubError.attachFailed(secondTimelineID)) {
            _ = try await service.resolveAvailableNetworkWorkspace(workspaceID)
        }

        #expect(backend.workspaceReference(timelineID: firstTimelineID, workspaceID: workspaceID) == oldBackendReference)
        #expect(backend.workspaceReference(timelineID: secondTimelineID, workspaceID: workspaceID) == oldBackendReference)
        #expect(await registry.workspace(id: workspaceID)?.status == .unavailable)
        #expect(await registry.attachmentIntent(for: firstTimelineID) == [.network(workspaceID, uri: uri)])
        #expect(await registry.attachmentIntent(for: secondTimelineID) == [.network(workspaceID, uri: uri)])

        backend.attachFailureTimelineID = nil
        _ = try await service.resolveAvailableNetworkWorkspace(workspaceID)

        #expect(await registry.workspace(id: workspaceID)?.status == .available)
        #expect(backend.workspaceReference(timelineID: firstTimelineID, workspaceID: workspaceID)?.tools.map(\.id) == [newTool.id])
        #expect(backend.workspaceReference(timelineID: secondTimelineID, workspaceID: workspaceID)?.tools.map(\.id) == [newTool.id])
    }

    @Test("Positronic Workspace state stays coherent across concurrent Timeline sessions")
    @MainActor
    func positronicWorkspaceStateStaysCoherentAcrossTimelines() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000051")!
        let firstTimelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000052")!
        let secondTimelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000053")!
        let workspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000054")!
        let reference = BackendWorkspaceReference(
            id: workspaceID,
            uri: "gnostic://workspace/positronic-shared",
            status: .available,
            tools: [.init(id: "shared_echo", name: "Shared echo", description: "Echoes input.")]
        )
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "Positronic",
            defaultTimelineID: firstTimelineID,
            backend: .init(kind: "positronic")
        )
        let timelines = [
            NodeManifest.Timeline(id: firstTimelineID, title: "First", operatingAscendantID: ascendantID),
            NodeManifest.Timeline(id: secondTimelineID, title: "Second", operatingAscendantID: ascendantID),
        ]
        let services = AscendantBackendServices(
            workspace: PositronicTestWorkspaceService(workspaceReference: reference),
            permission: AscendantBackendServices.empty.permission
        )
        let adapter = try await PositronicAscendantAdapter(
            ascendant: ascendant,
            backend: ascendant.backend,
            services: services,
            timelines: timelines,
            languageModel: UnconfiguredLLMService()
        )
        let firstTimeline = try await adapter.timeline(id: firstTimelineID)
        let secondTimeline = try await adapter.timeline(id: secondTimelineID)
        let first = try #require(firstTimeline as? any AscendantBackendTimelineWorkspaceSession)
        let second = try #require(secondTimeline as? any AscendantBackendTimelineWorkspaceSession)

        async let firstProjection = first.attachWorkspace(reference)
        async let secondProjection = second.attachWorkspace(reference)
        let projections = try await [firstProjection, secondProjection]

        #expect(projections.map { $0.id } == [firstTimelineID, secondTimelineID])
        #expect(try await adapter.operatedTimelines().map { $0.attachedWorkspaceIDs } == [[workspaceID], [workspaceID]])
        #expect(await first.enabledToolIDs().count == 1)
        #expect(await second.enabledToolIDs().count == 1)
    }

    @Test("a Workspace request with a retired Timeline session cannot resolve or attach")
    @MainActor
    func staleTimelineSessionCannotMutateDuringWorkspaceResolution() async throws {
        let ascendantID = UUID(uuidString: "13100000-0000-4000-8000-000000000061")!
        let timelineID = UUID(uuidString: "13100000-0000-4000-8000-000000000062")!
        let workspaceID = UUID(uuidString: "13100000-0000-4000-8000-000000000063")!
        let uri = "gnostic://workspace/stale-resolution"
        let oldReference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: uri)!,
            location: .attached
        )
        let oldBackendReference = BackendWorkspaceReference(reference: oldReference, status: .unavailable)
        let backend = ServiceStubAscendantBackend(
            ascendantID: ascendantID,
            timelineID: timelineID,
            initialAttachedWorkspaceIDs: [workspaceID],
            initialWorkspaceReferences: [workspaceID: oldBackendReference]
        )
        let control = StaleResolutionControl()
        let discovery = BlockingServiceStubWorkspaceDiscovery(
            entry: .init(
                objectID: workspaceID,
                objectType: GnosticObjectType.workspace,
                providerID: "stale-provider",
                name: "Stale workspace",
                knownProperties: [:],
                dynamicProperties: [:],
                workspace: .init(id: workspaceID, uri: uri, isAvailable: true, tools: [])
            ),
            control: control
        )
        let plan = try NodeManifest(
            broker: .init(host: "unused", port: 1883, namespace: "workspace-stale-resolution"),
            node: .init(id: UUID(uuidString: "13100000-0000-4000-8000-000000000064")!),
            ascendants: [.init(id: ascendantID, name: "Stub", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Stale", operatingAscendantID: ascendantID, attachments: [.network(workspaceID, uri: uri)])]
        ).compileLaunchPlan()
        let lease = UUID.makeVersion4()
        let leaseState = TestLeaseState(lease: lease)
        let registry = try NodeRegistry(
            plan: plan,
            operatedTimelines: try await backend.operatedTimelines(),
            backendLeases: [ascendantID: lease]
        )
        let provider = ClosureBackendSessionProvider(
            isRunning: { true },
            lifecycleGeneration: { 0 },
            adapter: { $0 == ascendantID ? backend : nil },
            current: { id, candidate, generation in
                id == ascendantID && generation == 0 && (candidate as AnyObject) === (backend as AnyObject)
            },
            backendLease: { id, candidate in
                id == ascendantID && (candidate as AnyObject) === (backend as AnyObject) ? leaseState.value : nil
            },
            failure: { _, _, _ in },
            backend: { _ in backend }
        )
        let service = WorkspaceService(
            plan: plan,
            registry: registry,
            discovery: discovery,
            localWorkspaces: [:],
            references: [workspaceID: oldReference],
            backendProvider: provider,
            readvertiseTimeline: { _ in }
        )

        let attach = Task { @MainActor in
            try? await service.attach(.init(workspaceID: workspaceID, timelineID: timelineID))
        }
        await control.waitForDiscovery()
        leaseState.value = UUID.makeVersion4()
        await control.releaseDiscovery()

        #expect(await attach.value == nil)
        #expect(await registry.workspace(id: workspaceID)?.status == .unavailable)
        #expect(backend.attachCalls.isEmpty)
        #expect(backend.workspaceReference(timelineID: timelineID, workspaceID: workspaceID) == oldBackendReference)
    }
}

@MainActor
private final class TestLeaseState {
    var value: UUID

    init(lease: UUID) {
        value = lease
    }
}

private struct PositronicTestWorkspaceService: AscendantBackendWorkspaceService {
    let workspaceReference: BackendWorkspaceReference

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        id == workspaceReference.id ? workspaceReference : nil
    }

    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        .init(message: "invoked \(invocation.toolID)")
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
private final class BlockingServiceStubWorkspaceDiscovery: WorkspaceDiscovery {
    private let entry: NetworkCatalogEntry
    private let control: StaleResolutionControl

    init(entry: NetworkCatalogEntry, control: StaleResolutionControl) {
        self.entry = entry
        self.control = control
    }

    func discover(timeout _: Duration) async {
        await control.markDiscovery()
        await control.waitForRelease()
    }

    func objects() async -> [NetworkCatalogEntry] { [entry] }

    func attachmentStatus(id _: UUID) async -> WorkspaceAttachmentStatus {
        .available(providerID: entry.providerID, uri: entry.workspace?.uri ?? "")
    }

    func queryTools(workspaceID _: UUID, timeout _: Duration) async {}

    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor? {
        guard providerID == entry.providerID, workspaceID == entry.workspace?.id else { return nil }
        return entry.workspace
    }
}

private actor StaleResolutionControl {
    private var discoveryStarted = false
    private var released = false
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForDiscovery() async {
        guard !discoveryStarted else { return }
        await withCheckedContinuation { continuation in
            discoveryWaiters.append(continuation)
        }
    }

    func markDiscovery() {
        discoveryStarted = true
        discoveryWaiters.forEach { $0.resume() }
        discoveryWaiters.removeAll()
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseDiscovery() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
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
private final class ServiceStubAscendantBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    fileprivate var storedTimelines: [AscendantBackendTimeline]
    fileprivate var workspaceReferencesByTimeline: [UUID: [UUID: BackendWorkspaceReference]]
    fileprivate var attachCalls: [UUID] = []
    private(set) var timelineSessionRequests = 0
    private(set) var operatedTimelinesRequests = 0
    fileprivate let returnedWorkspaceProjectionID: UUID?
    fileprivate var attachFailureTimelineID: UUID?
    fileprivate let attachControl: ServiceStubAttachControl?

    init(
        ascendantID: UUID,
        timelineID: UUID,
        returnedWorkspaceProjectionID: UUID? = nil,
        additionalTimelineIDs: [UUID] = [],
        initialAttachedWorkspaceIDs: [UUID] = [],
        initialWorkspaceReferences: [UUID: BackendWorkspaceReference] = [:],
        attachFailureTimelineID: UUID? = nil,
        attachControl: ServiceStubAttachControl? = nil
    ) {
        let now = Date()
        let timelineIDs = [timelineID] + additionalTimelineIDs
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
        storedTimelines = timelineIDs.map {
            .init(
                id: $0,
                title: "Before",
                attachedWorkspaceIDs: initialAttachedWorkspaceIDs,
                ascendantID: ascendantID,
                isArchived: false,
                isPrivate: false,
                createdAt: now,
                updatedAt: now
            )
        }
        workspaceReferencesByTimeline = Dictionary(uniqueKeysWithValues: timelineIDs.map {
            ($0, initialWorkspaceReferences)
        })
        self.returnedWorkspaceProjectionID = returnedWorkspaceProjectionID
        self.attachFailureTimelineID = attachFailureTimelineID
        self.attachControl = attachControl
    }

    func validateConfiguration() throws {}
    func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        operatedTimelinesRequests += 1
        return storedTimelines
    }
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        let timeline = AscendantBackendTimeline(id: id, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        storedTimelines.append(timeline)
        return timeline
    }
    func removeTimeline(id: UUID) async { storedTimelines.removeAll { $0.id == id } }
    func timeline(id: UUID) async throws -> any AscendantBackendTimelineSession {
        guard storedTimelines.contains(where: { $0.id == id }) else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        timelineSessionRequests += 1
        return ServiceStubTimelineSession(id: id, backend: self)
    }
    func cancel() async {}
    func shutdown() async {}

    fileprivate func workspaceReference(timelineID: UUID, workspaceID: UUID) -> BackendWorkspaceReference? {
        workspaceReferencesByTimeline[timelineID]?[workspaceID]
    }
}

@MainActor
private final class ServiceStubTimelineSession: AscendantBackendTimelineWorkspaceSession {
    let id: UUID
    private let backend: ServiceStubAscendantBackend

    init(id: UUID, backend: ServiceStubAscendantBackend) {
        self.id = id
        self.backend = backend
    }

    func runTurn(
        _ request: AscendantBackendTimelineTurnRequest,
        updates _: any AscendantBackendUpdateSink
    ) async throws -> String {
        "stub: \(request.message)"
    }

    func rename(to title: String) async throws -> AscendantBackendTimeline {
        guard let index = backend.storedTimelines.firstIndex(where: { $0.id == id }) else {
            throw NodeRuntimeError.missingTimeline(id)
        }
        let old = backend.storedTimelines[index]
        let renamed = AscendantBackendTimeline(
            id: old.id,
            title: title,
            attachedWorkspaceIDs: old.attachedWorkspaceIDs,
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
        backend.storedTimelines[index] = renamed
        return renamed
    }

    func attachWorkspace(_ reference: BackendWorkspaceReference) async throws -> AscendantBackendTimeline {
        backend.attachCalls.append(reference.id)
        if backend.attachFailureTimelineID == id {
            throw ServiceStubError.attachFailed(id)
        }
        guard let index = backend.storedTimelines.firstIndex(where: { $0.id == id }) else {
            throw NodeRuntimeError.missingTimeline(id)
        }
        let old = backend.storedTimelines[index]
        let attached = old.attachedWorkspaceIDs + (old.attachedWorkspaceIDs.contains(reference.id) ? [] : [reference.id])
        let projection = AscendantBackendTimeline(
            id: old.id,
            title: old.title,
            attachedWorkspaceIDs: attached,
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
        backend.storedTimelines[index] = projection
        backend.workspaceReferencesByTimeline[id, default: [:]][reference.id] = reference
        let result = AscendantBackendTimeline(
            id: backend.returnedWorkspaceProjectionID ?? projection.id,
            title: projection.title,
            attachedWorkspaceIDs: projection.attachedWorkspaceIDs,
            ascendantID: projection.ascendantID,
            isArchived: projection.isArchived,
            isPrivate: projection.isPrivate,
            createdAt: projection.createdAt,
            updatedAt: projection.updatedAt
        )
        await backend.attachControl?.pauseAfterMutation(reference.id)
        return result
    }

    func detachWorkspace(id workspaceID: UUID) async throws -> AscendantBackendTimeline {
        guard let index = backend.storedTimelines.firstIndex(where: { $0.id == id }) else {
            throw NodeRuntimeError.missingTimeline(id)
        }
        let old = backend.storedTimelines[index]
        let projection = AscendantBackendTimeline(
            id: old.id,
            title: old.title,
            attachedWorkspaceIDs: old.attachedWorkspaceIDs.filter { $0 != workspaceID },
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
        backend.storedTimelines[index] = projection
        backend.workspaceReferencesByTimeline[id]?.removeValue(forKey: workspaceID)
        return projection
    }

    func enabledToolIDs() async -> [String] { [] }
}

private enum ServiceStubError: Error, Sendable, Equatable {
    case attachFailed(UUID)
}

private actor ServiceStubAttachControl {
    private let firstWorkspaceID: UUID
    private var firstMutationObserved = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseFirst: CheckedContinuation<Void, Never>?

    init(firstWorkspaceID: UUID) {
        self.firstWorkspaceID = firstWorkspaceID
    }

    func waitForFirstMutation() async {
        if firstMutationObserved { return }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    func pauseAfterMutation(_ workspaceID: UUID) async {
        guard workspaceID == firstWorkspaceID, !firstMutationObserved else { return }
        firstMutationObserved = true
        mutationWaiters.forEach { $0.resume() }
        mutationWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseFirst = continuation
        }
    }

    func releaseFirstMutation() {
        releaseFirst?.resume()
        releaseFirst = nil
    }
}
