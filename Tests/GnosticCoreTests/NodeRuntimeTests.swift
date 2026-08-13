// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit
import Testing

@testable import GnosticCore

@Suite("Modular node runtime")
struct NodeRuntimeTests {
    @Test("runtime rejects an unregistered adapter before startup")
    func adapterRegistryFailureIsAtomic() async throws {
        let ascendantID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000131"))
        let timelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000132"))
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-adapter-tests"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000133")!),
            ascendants: [.init(id: ascendantID, name: "Unknown", defaultTimelineID: timelineID, kind: "unregistered")],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )

        await #expect(throws: NodeRuntimeError.unsupportedAscendantKind("unregistered")) {
            try await NodeRuntime(plan: manifest.compileLaunchPlan())
        }
    }

    @Test("network Workspace identities cannot collide with configured local objects")
    func networkWorkspaceIdentityCannotShadowLocalWorkspace() throws {
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000137")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000138")!
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-collision"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000139")!),
            timelines: [.init(id: timelineID, title: "Collision", attachments: [.network(workspaceID, uri: "workspace://remote")])],
            workspaces: [.init(id: workspaceID, name: "Local", uri: "echo://local")]
        )

        #expect(throws: NodeManifestError.duplicateID(workspaceID)) {
            try manifest.validate()
        }
    }

    @Test("multiplexed Workspace provider rejects a mismatched provider identity")
    func multiplexedWorkspaceProviderRejectsMismatchedProvider() async throws {
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000140")!
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "echo://provider-check")!,
            location: .runtime,
            tools: [.custom(.init(id: NodeRuntime.echoToolID, name: "Echo", description: "Echoes."))]
        )
        let provider = MultiplexedWorkspaceProvider(workspaces: [workspaceID: EchoWorkspace(reference: reference)])
        let invocation = WorkspaceInvocation(workspaceID: workspaceID, providerID: "other-node", toolID: NodeRuntime.echoToolID, arguments: [:])
        let payload = String(decoding: try JSONEncoder().encode(invocation), as: UTF8.self)

        await #expect(throws: WorkspaceError.connectionFailed) {
            _ = try await provider.handle(parameters: payload, expectedProviderID: "this-node")
        }
    }

    @Test("Core owns the validated launch plan and preserves unoperated timelines")
    func launchPlanBuildsStableRuntimeGraph() async throws {
        let nodeID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000101"))
        let ascendantID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000102"))
        let operatedTimelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000103"))
        let unoperatedTimelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000104"))
        let workspaceID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000105"))
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-tests"),
            node: .init(id: nodeID),
            ascendants: [.init(id: ascendantID, name: "Atlas", defaultTimelineID: operatedTimelineID, description: "Test Ascendant")],
            timelines: [
                .init(id: operatedTimelineID, title: "Operated", operatingAscendantID: ascendantID, attachments: [.local(workspaceID)]),
                .init(id: unoperatedTimelineID, title: "Unoperated"),
            ],
            workspaces: [.init(id: workspaceID, name: "Echo", uri: "echo://atlas")]
        )

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        let snapshot = await runtime.snapshot()

        #expect(snapshot.ascendantIDs == [ascendantID])
        #expect(snapshot.agentIDs == [ascendantID])
        #expect(snapshot.timelineIDs == [operatedTimelineID, unoperatedTimelineID])
        #expect(snapshot.operatedTimelineIDs == [operatedTimelineID])
        #expect(snapshot.workspaceIDs == [workspaceID])
        #expect(snapshot.agentIDs.contains(ascendantID))
    }

    @Test("empty node is a valid published graph with no modules")
    func emptyNodeHasNoPartialObjects() async throws {
        let manifest = NodeManifest.empty(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-empty")
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        let snapshot = await runtime.snapshot()

        #expect(snapshot.ascendantIDs.isEmpty)
        #expect(snapshot.timelineIDs.isEmpty)
        #expect(snapshot.workspaceIDs.isEmpty)
        #expect(try await runtime.listTimelines().isEmpty)
    }

    @Test("operated timelines route to their own ascendant runtime")
    func disjointTimelineRouting() async throws {
        let first = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000127"))
        let firstTimeline = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000128"))
        let second = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000129"))
        let secondTimeline = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000130"))
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-routing"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000135")!),
            ascendants: [
                .init(id: first, name: "First", defaultTimelineID: firstTimeline),
                .init(id: second, name: "Second", defaultTimelineID: secondTimeline),
            ],
            timelines: [
                .init(id: firstTimeline, title: "First", operatingAscendantID: first),
                .init(id: secondTimeline, title: "Second", operatingAscendantID: second),
                .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000136")!, title: "Unoperated"),
            ]
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())

        #expect(await runtime.ascendantID(forTimeline: firstTimeline) == first)
        #expect(await runtime.ascendantID(forTimeline: secondTimeline) == second)
        #expect(try await runtime.listTimelines().count == 3)
    }

    @Test("one running runtime multiplexes configured echo workspaces") @MainActor
    func echoWorkspacesShareTheProviderRoute() async throws {
        let manifest = try makeManifest(
            ascendantID: "A21D0000-0000-4000-8000-000000000112",
            timelineID: "A21D0000-0000-4000-8000-000000000113",
            workspaceIDs: [
                "A21D0000-0000-4000-8000-000000000114",
                "A21D0000-0000-4000-8000-000000000115",
            ]
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let first = try await runtime.executeWorkspaceTool(
            workspaceID: try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000114")),
            toolID: "workspace_echo",
            arguments: ["value": AnyCodable("first")]
        )
        let second = try await runtime.executeWorkspaceTool(
            workspaceID: try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000115")),
            toolID: "workspace_echo",
            arguments: ["value": AnyCodable("second")]
        )

        #expect(first.output == "first")
        #expect(second.output == "second")
        #expect(runtime.advertisedWorkspaceIDs() == [
            UUID(uuidString: "A21D0000-0000-4000-8000-000000000114")!,
            UUID(uuidString: "A21D0000-0000-4000-8000-000000000115")!,
        ])
    }

    @Test("chat addressed to an unoperated timeline returns a structured operating-ascendant error")
    func unoperatedTimelineRejectsChat() async throws {
        let ascendantID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000116"))
        let operatedID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000117"))
        let unoperatedID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000118"))
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-unoperated-chat"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000119")!),
            ascendants: [.init(id: ascendantID, name: "Atlas", defaultTimelineID: operatedID)],
            timelines: [
                .init(id: operatedID, title: "Operated", operatingAscendantID: ascendantID),
                .init(id: unoperatedID, title: "Unoperated"),
            ]
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())

        await #expect(throws: NodeRuntimeError.noOperatingAscendant(unoperatedID)) {
            _ = try await runtime.chat(AgentChatRequest(message: "hello", timelineID: unoperatedID))
        }
    }

    @Test("runtime-created timelines bind to the selected ascendant and are process-only")
    func runtimeTimelineUsesSelectedAscendant() async throws {
        let first = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000120"))
        let firstTimeline = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000121"))
        let second = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000122"))
        let secondTimeline = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000123"))
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-created-timeline"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000124")!),
            ascendants: [
                .init(id: first, name: "First", defaultTimelineID: firstTimeline),
                .init(id: second, name: "Second", defaultTimelineID: secondTimeline),
            ],
            timelines: [
                .init(id: firstTimeline, title: "First default", operatingAscendantID: first),
                .init(id: secondTimeline, title: "Second default", operatingAscendantID: second),
            ]
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())

        let created = try await runtime.createTimeline(title: "Scratch", ascendantID: second)

        #expect(await runtime.ascendantID(forTimeline: created.timelineID) == second)
        #expect(await runtime.timeline(id: created.timelineID)?.attachedAgentInstanceID == second)
        #expect(await runtime.ascendantRuntime(id: second)?.timelineManager.timeline(id: created.timelineID)?.attachedAgentInstanceID == second)
        #expect(await runtime.snapshot().timelineIDs.contains(created.timelineID))
        #expect(!(await runtime.launchPlan).timelines.contains { $0.id == created.timelineID })
    }

    @Test("graceful shutdown rejects new work")
    func shutdownRejectsNewWork() async throws {
        let manifest = try makeManifest(
            ascendantID: "A21D0000-0000-4000-8000-000000000125",
            timelineID: "A21D0000-0000-4000-8000-000000000126",
            workspaceIDs: []
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        await runtime.shutdown()

        await #expect(throws: NodeRuntimeError.notRunning) {
            _ = try await runtime.createTimeline(title: "Rejected", ascendantID: UUID(uuidString: "A21D0000-0000-4000-8000-000000000125")!)
        }
        await #expect(throws: NodeRuntimeError.notRunning) {
            _ = try await runtime.executeWorkspaceTool(workspaceID: UUID(), toolID: "workspace_echo", arguments: [:])
        }
    }

    @Test("startup failure rolls back the node before publication") @MainActor
    func injectedStartupFailureIsAtomic() async throws {
        let manifest = NodeManifest.empty(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-startup-rollback")
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.lifecycle = .init(afterRegistration: { throw InjectedStartupFailure() })
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)

        await #expect(throws: InjectedStartupFailure.self) {
            try await runtime.start()
        }
        #expect(runtime.isRunning == false)
        await #expect(throws: NodeRuntimeError.notRunning) {
            _ = try await runtime.createTimeline(title: "not published", ascendantID: UUID())
        }
    }

    @Test("advertised workspaces are callable before startup returns") @MainActor
    func advertisedWorkspaceIsAvailableBeforeStartReturns() async throws {
        let gate = LifecycleGate()
        let namespace = "node-runtime-advertisement-lifecycle"
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000149")!
        let manifest = try makeManifest(
            namespace: namespace,
            ascendantID: "A21D0000-0000-4000-8000-000000000150",
            timelineID: "A21D0000-0000-4000-8000-000000000151",
            workspaceIDs: [workspaceID.uuidString]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.lifecycle.afterAdvertisement = { await gate.hold() }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        let consumer = makeNodeRuntimeBrokerManager("advertisement-lifecycle-consumer", namespace: namespace)
        defer { consumer.stop() }
        try await startNodeRuntimeBrokerManager(consumer)

        let startup = Task { @MainActor in try await runtime.start() }
        await gate.waitUntilOpened()

        let payload = try JSONEncoder().encode(WorkspaceInvocation(
            workspaceID: workspaceID,
            toolID: NodeRuntime.echoToolID,
            arguments: ["value": AnyCodable("during-advertisement")]
        ))
        let response = try? await consumer.call(
            operation: WorkspaceProvider.invocationOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            timeout: Duration.seconds(1)
        )
        let result = response.flatMap { try? JSONDecoder().decode(ToolResult.self, from: Data($0.result.utf8)) }
        #expect(result?.output == "during-advertisement")

        await gate.release()
        try await startup.value
        await runtime.shutdown()
    }

    @Test("shutdown during startup leaves no late discover responder") @MainActor
    func shutdownDuringStartupCleansLateRegistrations() async throws {
        let namespace = "node-runtime-concurrent-shutdown"
        let gate = LifecycleGate()
        let manifest = try makeManifest(
            namespace: namespace,
            ascendantID: "A21D0000-0000-4000-8000-000000000152",
            timelineID: "A21D0000-0000-4000-8000-000000000153",
            workspaceIDs: ["A21D0000-0000-4000-8000-000000000154"]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.lifecycle.beforeDiscoverResponder = { await gate.hold() }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)

        let consumer = makeNodeRuntimeBrokerManager("concurrent-shutdown-consumer", namespace: namespace)
        defer { consumer.stop() }
        try await startNodeRuntimeBrokerManager(consumer)
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }

        let startup = Task { @MainActor in try await runtime.start() }
        await gate.waitUntilOpened()
        await runtime.shutdown()
        await gate.release()

        let startupResult = await startup.result
        let startupFailed: Bool
        switch startupResult {
        case .success:
            startupFailed = false
        case .failure:
            startupFailed = true
        }
        #expect(startupFailed)
        #expect(runtime.isRunning == false)

        await subscription.discover(using: consumer, timeout: Duration.milliseconds(300))
        #expect(await catalog.networkObjects().isEmpty)
        await runtime.shutdown()
    }

    @Test("discover responder stays silent until the node is running") @MainActor
    func discoverResponderDoesNotPublishDuringStartup() async throws {
        let namespace = "node-runtime-discover-startup"
        let gate = LifecycleGate()
        let manifest = try makeManifest(
            namespace: namespace,
            ascendantID: "A21D0000-0000-4000-8000-000000000155",
            timelineID: "A21D0000-0000-4000-8000-000000000156",
            workspaceIDs: ["A21D0000-0000-4000-8000-000000000157"]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.lifecycle.afterDiscoverResponder = { await gate.hold() }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        let consumer = makeNodeRuntimeBrokerManager("discover-startup-consumer", namespace: namespace)
        defer { consumer.stop() }
        try await startNodeRuntimeBrokerManager(consumer)
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }

        let startup = Task { @MainActor in try await runtime.start() }
        await gate.waitUntilOpened()
        await subscription.discover(using: consumer, timeout: Duration.milliseconds(300))
        #expect(await catalog.networkObjects().isEmpty)

        await gate.release()
        try await startup.value
        await subscription.discover(using: consumer, timeout: Duration.milliseconds(300))
        #expect(await catalog.networkObjects().isEmpty == false)
        await runtime.shutdown()
    }

    @Test("runtime advertises complete objects over the broker") @MainActor
    func runtimeAdvertisesCompleteObjects() async throws {
        let namespace = "node-runtime-broker-tests"
        let manifest = try makeManifest(
            namespace: namespace,
            ascendantID: "A21D0000-0000-4000-8000-000000000122",
            timelineID: "A21D0000-0000-4000-8000-000000000123",
            workspaceIDs: ["A21D0000-0000-4000-8000-000000000124"]
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        defer { Task { @MainActor in await runtime.shutdown() } }

        try await runtime.start()
        let consumer = try CommunicationManager(
            identity: Identity(name: "node-runtime-consumer"),
            communicationOptions: .init(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: .init(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
        defer { consumer.stop() }

        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }
        try consumer.start()
        await subscription.discover(using: consumer, timeout: .seconds(1))

        for _ in 0..<30 {
            if await Set(catalog.networkObjects().map(\.objectType)).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await Set(catalog.networkObjects().map(\.objectType)) == Set([
            GnosticObjectType.agent,
            GnosticObjectType.timeline,
            GnosticObjectType.workspace,
        ]))

        let update = TimelineUpdateRequest(timelineID: manifest.timelines[0].id, title: "Renamed")
        let payload = String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
        _ = try await consumer.call(operation: TimelineManagementProvider.updateOperation, parameters: payload, timeout: .seconds(3))
        #expect(runtime.timeline(id: manifest.timelines[0].id)?.title == "Renamed")
        await subscription.discover(using: consumer, timeout: .seconds(1))
        for _ in 0..<20 {
            if await catalog.networkObjects().first(where: { $0.objectID == manifest.timelines[0].id })?.name == "Renamed" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await catalog.networkObjects().first(where: { $0.objectID == manifest.timelines[0].id })?.name == "Renamed")
    }

    @Test("startup actively discovers an already-online lazy Workspace") @MainActor
    func existingNetworkWorkspaceResolvesOnStartup() async throws {
        let namespace = "node-runtime-existing-workspace"
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000145")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000146")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000147")!
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://existing")!,
            location: .runtime,
            tools: [.custom(.init(id: "existing_echo", name: "Existing echo", description: "Already online."))]
        )
        let object = GnosticWorkspaceObject(workspace: reference)
        let remote = try CommunicationManager(
            identity: Identity(name: "existing-workspace-provider"),
            communicationOptions: .init(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: .init(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
        let responder = await remote.registerDiscoverResponder { request in try request.resolve(object: object) }
        defer { responder.cancel(); remote.stop() }
        try remote.start()

        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000148")!),
            ascendants: [.init(id: ascendantID, name: "Atlas", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID, attachments: [.network(workspaceID, uri: "workspace://existing")])]
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        for _ in 0..<30 where runtime.workspaceReference(id: workspaceID)?.tools.isEmpty != false {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(runtime.workspaceReference(id: workspaceID)?.tools.first?.toolID == "existing_echo")
    }

    @Test("late unambiguous advertisement automatically resolves a lazy network attachment") @MainActor
    func lateNetworkWorkspaceResolvesAutomatically() async throws {
        let namespace = "node-runtime-late-workspace"
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000141")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000142")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000143")!
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000144")!),
            ascendants: [.init(id: ascendantID, name: "Atlas", defaultTimelineID: timelineID)],
            timelines: [.init(
                id: timelineID,
                title: "Default",
                operatingAscendantID: ascendantID,
                attachments: [.network(workspaceID, uri: "workspace://remote-late")]
            )]
        )
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }
        #expect(runtime.workspaceReference(id: workspaceID)?.tools.isEmpty == true)
        let manager = try #require(runtime.ascendantRuntime(id: ascendantID)?.timelineManager)
        try await manager.ensureTimelineExists(id: timelineID)
        #expect(await manager.enabledTools(for: timelineID).contains { $0.callName == "remote_echo" } == false)

        let remote = try CommunicationManager(
            identity: Identity(name: "late-workspace-provider"),
            communicationOptions: .init(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: .init(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
        try remote.start()
        defer { remote.stop() }
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://remote-late")!,
            location: .runtime,
            tools: [.custom(.init(id: "remote_echo", name: "Remote echo", description: "Echoes remotely."))]
        )
        remote.publishAdvertise(try AdvertiseEvent.with(object: GnosticWorkspaceObject(workspace: reference)))

        for _ in 0..<40 where runtime.workspaceReference(id: workspaceID)?.tools.isEmpty != false {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(runtime.workspaceReference(id: workspaceID)?.tools.isEmpty == false)
        #expect(await manager.enabledTools(for: timelineID).contains { $0.callName == "remote_echo" })
    }

    private func makeManifest(
        namespace: String = "node-runtime-tests",
        ascendantID: String,
        timelineID: String,
        workspaceIDs: [String]
    ) throws -> NodeManifest {
        let ascendant = try #require(UUID(uuidString: ascendantID))
        let timeline = try #require(UUID(uuidString: timelineID))
        let workspaces = try workspaceIDs.map { value in
            let id = try #require(UUID(uuidString: value))
            return NodeManifest.Workspace(id: id, name: "Echo \(value.suffix(4))", uri: "echo://\(value.suffix(4))")
        }
        return NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000111")!),
            ascendants: [.init(id: ascendant, name: "Atlas", defaultTimelineID: timeline)],
            timelines: [.init(id: timeline, title: "Default", operatingAscendantID: ascendant, attachments: workspaceIDs.compactMap { UUID(uuidString: $0) }.map(NodeManifest.WorkspaceAttachment.local))],
            workspaces: workspaces
        )
    }
}

private struct InjectedStartupFailure: Error, Sendable, Equatable {}

private actor LifecycleGate {
    private var opened = false
    private var released = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        guard !released else { return }
        opened = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }, onCancel: {
            Task { await self.release() }
        })
    }

    func waitUntilOpened() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                openWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

@MainActor
private func makeNodeRuntimeBrokerManager(_ name: String, namespace: String) -> CommunicationManager {
    let options = CommunicationOptions(
        namespace: namespace,
        shouldEnableCrossNamespacing: false,
        mqttClientOptions: MQTTClientOptions(
            host: "127.0.0.1",
            port: 1883,
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        ),
        shouldAutoStart: false
    )
    return try! CommunicationManager(
        identity: Identity(name: name),
        communicationOptions: options,
        commonOptions: nil
    )
}

@MainActor
private func startNodeRuntimeBrokerManager(_ manager: CommunicationManager) async throws {
    let stream = await manager.observeCommunicationStateStream()
    var iterator = stream.makeAsyncIterator()
    try manager.start()
    while let state = await iterator.next() {
        if state == .online { return }
    }
    throw CancellationError()
}
