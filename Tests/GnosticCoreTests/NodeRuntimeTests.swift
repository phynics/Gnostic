// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit
import Testing

@testable import GnosticCore

@Suite("Modular node runtime")
struct NodeRuntimeTests {
    @Test("a non-Positronic Ascendant adapter owns timeline and turn behavior at the NodeRuntime seam")
    @MainActor
    func customAscendantAdapterDoesNotRequirePositronicKit() async throws {
        let ascendantID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000211"))
        let timelineID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000212"))
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-custom-ascendant"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000213")!),
            ascendants: [.init(id: ascendantID, name: "Fixture", defaultTimelineID: timelineID, kind: "fixture")],
            timelines: [.init(id: timelineID, title: "Fixture timeline", operatingAscendantID: ascendantID)]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "fixture") { ascendant, _, _, timelines in
            FixtureAscendantBackend(ascendant: ascendant, timelines: timelines)
        }

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        #expect(try await runtime.listTimelines().map(\.timelineID) == [timelineID])
        #expect(try await runtime.turn(.init(message: "hello", timelineID: timelineID)).text == "fixture: hello")
        let created = try await runtime.createTimeline(title: "Scratch", ascendantID: ascendantID)
        #expect(created.title == "Scratch")
    }

    @Test("node shutdown asks each Ascendant adapter to cancel provider work")
    @MainActor
    func customAdapterOwnsTurnCancellation() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000214")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000215")!
        let probe = AdapterCancellationProbe()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-adapter-cancellation"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000216")!),
            ascendants: [.init(id: ascendantID, name: "Fixture", defaultTimelineID: timelineID, kind: "fixture")],
            timelines: [.init(id: timelineID, title: "Fixture timeline", operatingAscendantID: ascendantID)]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "fixture") { ascendant, _, _, timelines in
            FixtureAscendantBackend(ascendant: ascendant, timelines: timelines, cancellationProbe: probe)
        }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await runtime.start()
        let chat = Task {
            try await runtime.turn(.init(message: "wait", timelineID: timelineID, clientTurnID: "cancel-me"))
        }

        await probe.waitUntilStarted()
        await runtime.shutdown()

        #expect(await probe.wasCancelled)
        switch await chat.result {
        case .success:
            Issue.record("The cancelled adapter turn unexpectedly succeeded.")
        case let .failure(error):
            #expect(error as? AscendantTurnError == .cancelled(timelineID: timelineID, clientTurnID: "cancel-me"))
        }
    }

    @Test("a rejected adapter-created Timeline is removed from adapter and registry")
    @MainActor
    func runtimeTimelineCreationCompensatesAdapterFailure() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000218")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000219")!
        let probe = AdapterCreationProbe()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-runtime-create-compensation"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000220")!),
            ascendants: [.init(id: ascendantID, name: "Fixture", defaultTimelineID: timelineID, kind: "fixture")],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "fixture") { ascendant, _, _, timelines in
            FixtureAscendantBackend(ascendant: ascendant, timelines: timelines, creationProbe: probe)
        }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)

        await #expect(throws: NodeRuntimeError.self) {
            _ = try await runtime.createTimeline(title: "Rejected", ascendantID: ascendantID)
        }

        #expect(await runtime.snapshot().timelineIDs == [timelineID])
        #expect(await probe.removedIDs.count == 2)
    }

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

        let response = try await provider.handle(parameters: payload, expectedProviderID: "this-node")
        guard case let .failure(_, message, _) = response else {
            Issue.record("expected a structured provider-routing failure")
            return
        }
        let failure = try JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(message.utf8))
        #expect(failure.protocolMajor == GnosticProtocol.currentMajor)
        #expect(failure.reasonCode == "workspaceInvocationFailed")
    }

    @Test("multiplexed Workspace provider preserves cancellation from a workspace")
    func multiplexedWorkspaceProviderPreservesCancellation() async throws {
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000141")!
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "echo://provider-cancellation")!,
            location: .runtime,
            tools: [.custom(.init(id: NodeRuntime.echoToolID, name: "Echo", description: "Echoes."))]
        )
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [workspaceID: CancellationWorkspace(reference: reference)]
        )
        let invocation = WorkspaceInvocation(workspaceID: workspaceID, toolID: NodeRuntime.echoToolID, arguments: [:])
        let payload = String(decoding: try JSONEncoder().encode(invocation), as: UTF8.self)

        await #expect(throws: CancellationError.self) {
            _ = try await provider.handle(parameters: payload)
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
        #expect(snapshot.timelineIDs == [operatedTimelineID, unoperatedTimelineID])
        #expect(snapshot.operatedTimelineIDs == [operatedTimelineID])
        #expect(snapshot.workspaceIDs == [workspaceID])
        #expect(snapshot.ascendantIDs.contains(ascendantID))
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

    @Test("two nodes in one namespace route Timeline status only to the addressed provider") @MainActor
    func twoNodeTimelineStatusUsesProviderScope() async throws {
        let namespace = "node-runtime-two-provider-status"
        let firstTimeline = UUID(uuidString: "A21D0000-0000-4000-8000-000000000161")!
        let secondTimeline = UUID(uuidString: "A21D0000-0000-4000-8000-000000000162")!
        let firstManifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000163")!),
            ascendants: [.init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000164")!, name: "First", defaultTimelineID: firstTimeline)],
            timelines: [.init(id: firstTimeline, title: "First Node Timeline", operatingAscendantID: UUID(uuidString: "A21D0000-0000-4000-8000-000000000164")!)]
        )
        let secondManifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000165")!),
            ascendants: [.init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000166")!, name: "Second", defaultTimelineID: secondTimeline)],
            timelines: [.init(id: secondTimeline, title: "Second Node Timeline", operatingAscendantID: UUID(uuidString: "A21D0000-0000-4000-8000-000000000166")!)]
        )
        let first = try await NodeRuntime(plan: firstManifest.compileLaunchPlan())
        let second = try await NodeRuntime(plan: secondManifest.compileLaunchPlan())
        try await first.start()
        try await second.start()
        defer {
            Task { @MainActor in
                await first.shutdown()
                await second.shutdown()
            }
        }

        let consumer = makeNodeRuntimeBrokerManager("two-provider-status-consumer", namespace: namespace)
        defer { consumer.stop() }
        try await startNodeRuntimeBrokerManager(consumer)
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }
        await subscription.discover(using: consumer, timeout: .seconds(2))

        let target = try #require(await catalog.networkObjects().first {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == secondTimeline
        })
        let payload = String(decoding: try JSONEncoder().encode(TimelineStatusRequest(timelineID: secondTimeline)), as: UTF8.self)
        let response = try await consumer.call(
            operation: TimelineStatusProvider.statusOperation,
            parameters: payload,
            context: ObjectFilter(condition: ObjectFilterCondition(
                property: ObjectFilterProperty("objectId"),
                expression: .equals(FilterOperand(target.providerID.lowercased()))
            )),
            timeout: .seconds(2)
        )
        let status = try JSONDecoder().decode(TimelineStatus.self, from: Data(response.result.utf8))
        #expect(response.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(status.title == "Second Node Timeline")
    }

    @Test("two nodes in one namespace address chat and replay to the selected language model") @MainActor
    func twoNodeChatAndReplayUseProviderScope() async throws {
        let namespace = "node-runtime-two-provider-chat"
        let firstTimeline = UUID(uuidString: "A21D0000-0000-4000-8000-000000000171")!
        let secondTimeline = UUID(uuidString: "A21D0000-0000-4000-8000-000000000172")!
        let firstModel = ProviderIsolationLanguageModel(response: "first-model-response")
        let secondModel = ProviderIsolationLanguageModel(response: "second-model-response")
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.register(kind: "positronic") { _, backend in
            switch backend.settings["model"]?.stringValue {
            case "first-model": return firstModel
            case "second-model": return secondModel
            default: return UnconfiguredLLMService()
            }
        }
        let firstManifest = try makeProviderIsolationManifest(
            namespace: namespace,
            nodeID: "A21D0000-0000-4000-8000-000000000173",
            ascendantID: "A21D0000-0000-4000-8000-000000000174",
            timelineID: firstTimeline,
            profileID: "A21D0000-0000-4000-8000-000000000175",
            profileModel: "first-model"
        )
        let secondManifest = try makeProviderIsolationManifest(
            namespace: namespace,
            nodeID: "A21D0000-0000-4000-8000-000000000176",
            ascendantID: "A21D0000-0000-4000-8000-000000000177",
            timelineID: secondTimeline,
            profileID: "A21D0000-0000-4000-8000-000000000178",
            profileModel: "second-model"
        )
        let first = try await NodeRuntime(plan: firstManifest.compileLaunchPlan(), adapters: adapters)
        let second = try await NodeRuntime(plan: secondManifest.compileLaunchPlan(), adapters: adapters)
        try await first.start()
        try await second.start()
        defer {
            Task { @MainActor in
                await first.shutdown()
                await second.shutdown()
            }
        }

        let consumer = makeNodeRuntimeBrokerManager("two-provider-chat-consumer", namespace: namespace)
        defer { consumer.stop() }
        try await startNodeRuntimeBrokerManager(consumer)
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }
        await subscription.discover(using: consumer, timeout: .seconds(2))

        let target = try #require(await catalog.networkObjects().first {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == secondTimeline
        })
        let request = AscendantTurnRequest(message: "provider isolation", timelineID: secondTimeline, clientTurnID: "provider-turn-2")
        let response = try await consumer.call(
            operation: AscendantTurnProvider.turnOperation,
            parameters: String(decoding: try JSONEncoder().encode(request), as: UTF8.self),
            context: providerIsolationContext(target.providerID),
            timeout: .seconds(3)
        )
        let result = try JSONDecoder().decode(AscendantTurnResult.self, from: Data(response.result.utf8))
        #expect(response.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(result.text == "second-model-response")
        #expect(await firstModel.invocationCount == 0)
        #expect(await secondModel.invocationCount == 1)

        let replayRequest = AscendantTurnReplayRequest(timelineID: secondTimeline, clientTurnID: "provider-turn-2")
        let replayResponse = try await consumer.call(
            operation: AscendantTurnProvider.replayOperation,
            parameters: String(decoding: try JSONEncoder().encode(replayRequest), as: UTF8.self),
            context: providerIsolationContext(target.providerID),
            timeout: .seconds(3)
        )
        let replay = try JSONDecoder().decode(
            AscendantTurnReplay.self,
            from: Data(replayResponse.result.utf8)
        )
        #expect(replayResponse.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(replay.terminal)
        #expect(replay.updates.last?.text == "second-model-response")
        #expect(await firstModel.invocationCount == 0)
        #expect(await secondModel.invocationCount == 1)
    }

    @Test("two nodes in one namespace address timeline and workspace management to one provider") @MainActor
    func twoNodeManagementUsesProviderScope() async throws {
        let namespace = "node-runtime-two-provider-management"
        let firstNodeID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000181")!
        let firstAscendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000182")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000183")!
        let firstWorkspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000184")!
        let secondNodeID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000185")!
        let secondAscendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000186")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000187")!
        let secondWorkspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000188")!
        let firstManifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: firstNodeID),
            ascendants: [.init(id: firstAscendantID, name: "First", defaultTimelineID: firstTimelineID)],
            timelines: [.init(id: firstTimelineID, title: "First timeline", operatingAscendantID: firstAscendantID)],
            workspaces: [.init(id: firstWorkspaceID, name: "First workspace", uri: "echo://first")]
        )
        let secondManifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: secondNodeID),
            ascendants: [.init(id: secondAscendantID, name: "Second", defaultTimelineID: secondTimelineID)],
            timelines: [.init(id: secondTimelineID, title: "Second timeline", operatingAscendantID: secondAscendantID)],
            workspaces: [.init(id: secondWorkspaceID, name: "Second workspace", uri: "echo://second")]
        )
        let first = try await NodeRuntime(plan: firstManifest.compileLaunchPlan())
        let second = try await NodeRuntime(plan: secondManifest.compileLaunchPlan())
        try await first.start()
        try await second.start()
        defer {
            Task { @MainActor in
                await first.shutdown()
                await second.shutdown()
            }
        }

        let consumer = makeNodeRuntimeBrokerManager("two-provider-management-consumer", namespace: namespace)
        defer { consumer.stop() }
        try await startNodeRuntimeBrokerManager(consumer)
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }
        await subscription.discover(using: consumer, timeout: .seconds(2))

        let target = try #require(await catalog.networkObjects().first {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == secondTimelineID
        })
        let context = providerIsolationContext(target.providerID)
        let initialFirstTimeline = try #require(await first.timeline(id: firstTimelineID))
        let initialSecondTimeline = try #require(await second.timeline(id: secondTimelineID))

        let createResponse = try await consumer.call(
            operation: TimelineManagementProvider.createOperation,
            parameters: String(decoding: try JSONEncoder().encode(TimelineCreateRequest(title: "Second scratch", ascendantID: secondAscendantID)), as: UTF8.self),
            context: context,
            timeout: .seconds(3)
        )
        let created = try JSONDecoder().decode(TimelineStatus.self, from: Data(createResponse.result.utf8))
        #expect(createResponse.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(created.title == "Second scratch")
        #expect(await second.timeline(id: created.timelineID)?.title == "Second scratch")
        #expect(await first.timeline(id: created.timelineID) == nil)
        await subscription.discover(using: consumer, timeout: .seconds(1))
        for _ in 0..<20 {
            if await catalog.networkObjects().contains(where: {
                $0.objectType == GnosticObjectType.timeline && $0.objectID == created.timelineID
            }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await catalog.networkObjects().contains {
            $0.objectType == GnosticObjectType.timeline
                && $0.objectID == created.timelineID
                && $0.providerID == target.providerID
        })

        let listResponse = try await consumer.call(
            operation: TimelineManagementProvider.listOperation,
            parameters: String(decoding: try JSONEncoder().encode(TimelineListRequest()), as: UTF8.self),
            context: context,
            timeout: .seconds(3)
        )
        let listed = try JSONDecoder().decode(TimelineListResult.self, from: Data(listResponse.result.utf8))
        #expect(listResponse.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(listed.timelines.map(\.timelineID).contains(secondTimelineID))
        #expect(listed.timelines.map(\.timelineID).contains(created.timelineID))
        #expect(!listed.timelines.map(\.timelineID).contains(firstTimelineID))

        let updateResponse = try await consumer.call(
            operation: TimelineManagementProvider.updateOperation,
            parameters: String(decoding: try JSONEncoder().encode(TimelineUpdateRequest(timelineID: secondTimelineID, title: "Second renamed")), as: UTF8.self),
            context: context,
            timeout: .seconds(3)
        )
        let updated = try JSONDecoder().decode(TimelineStatus.self, from: Data(updateResponse.result.utf8))
        #expect(updateResponse.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(updated.title == "Second renamed")
        #expect(await second.timeline(id: secondTimelineID)?.title == "Second renamed")
        #expect(await first.timeline(id: firstTimelineID)?.title == initialFirstTimeline.title)
        #expect(await first.timeline(id: firstTimelineID)?.attachedWorkspaceIDs == initialFirstTimeline.attachedWorkspaceIDs)

        let workspaceListResponse = try await consumer.call(
            operation: WorkspaceOpsProvider.listOperation,
            parameters: String(decoding: try JSONEncoder().encode(WorkspaceOpsRequest(workspaceID: secondWorkspaceID, timelineID: secondTimelineID)), as: UTF8.self),
            context: context,
            timeout: .seconds(3)
        )
        let workspaceList = try JSONDecoder().decode(WorkspaceListResult.self, from: Data(workspaceListResponse.result.utf8))
        #expect(workspaceListResponse.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(workspaceList.workspaces.contains { $0.id == secondWorkspaceID && $0.name == "Second workspace" })

        let attachmentRequest = WorkspaceOpsRequest(workspaceID: secondWorkspaceID, timelineID: secondTimelineID)
        let attachResponse = try await consumer.call(
            operation: WorkspaceOpsProvider.attachOperation,
            parameters: String(decoding: try JSONEncoder().encode(attachmentRequest), as: UTF8.self),
            context: context,
            timeout: .seconds(3)
        )
        #expect(attachResponse.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(try JSONDecoder().decode(WorkspaceMutationResult.self, from: Data(attachResponse.result.utf8)).accepted)
        #expect(await second.timeline(id: secondTimelineID)?.attachedWorkspaceIDs == [secondWorkspaceID])
        #expect(await first.timeline(id: firstTimelineID)?.title == initialFirstTimeline.title)
        #expect(await first.timeline(id: firstTimelineID)?.attachedWorkspaceIDs == initialFirstTimeline.attachedWorkspaceIDs)

        let detachResponse = try await consumer.call(
            operation: WorkspaceOpsProvider.detachOperation,
            parameters: String(decoding: try JSONEncoder().encode(attachmentRequest), as: UTF8.self),
            context: context,
            timeout: .seconds(3)
        )
        #expect(detachResponse.sourceId?.lowercased() == target.providerID.lowercased())
        #expect(try JSONDecoder().decode(WorkspaceMutationResult.self, from: Data(detachResponse.result.utf8)).accepted)
        #expect(await second.timeline(id: secondTimelineID)?.attachedWorkspaceIDs.isEmpty == true)
        #expect(await second.timeline(id: secondTimelineID)?.title == "Second renamed")
        #expect(await first.timeline(id: firstTimelineID)?.title == initialFirstTimeline.title)
        #expect(await first.timeline(id: firstTimelineID)?.attachedWorkspaceIDs == initialFirstTimeline.attachedWorkspaceIDs)
        #expect(await second.timeline(id: secondTimelineID)?.attachedAscendantID == initialSecondTimeline.attachedAscendantID)
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
            _ = try await runtime.turn(AscendantTurnRequest(message: "hello", timelineID: unoperatedID))
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
        #expect(await runtime.timeline(id: created.timelineID)?.attachedAscendantID == second)
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

    @Test("Ascendant turns receive network tools without filesystem tools") @MainActor
    func ascendantTurnsUseNetworkOnlyTools() async throws {
        let manifest = try makeManifest(
            namespace: "node-runtime-turn-tools",
            ascendantID: "A21D0000-0000-4000-8000-000000000191",
            timelineID: "A21D0000-0000-4000-8000-000000000192",
            workspaceIDs: []
        )
        let languageModel = NodeToolCaptureLanguageModel()
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.register(kind: "positronic") { _, _ in languageModel }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        defer { Task { @MainActor in await runtime.shutdown() } }
        try await runtime.start()

        _ = try await runtime.turn(AscendantTurnRequest(
            message: "find a workspace",
            timelineID: manifest.timelines[0].id
        ))

        #expect(await languageModel.toolNames().isSuperset(of: [
            "list_network_objects",
            "inspect_network_object",
            "attach_workspace",
        ]))
        #expect(await languageModel.toolNames().isDisjoint(with: [
            "Change Directory",
            "List Directory",
            "Find File",
            "Search File Content",
            "Search Files",
            "Read File",
        ]))
    }

    @Test("runtime does not heartbeat Timeline advertisements") @MainActor
    func runtimeDoesNotHeartbeatAdvertisements() async throws {
        let namespace = "node-runtime-advertisement-tests"
        let manifest = try makeManifest(
            namespace: namespace,
            ascendantID: "A21D0000-0000-4000-8000-000000000193",
            timelineID: "A21D0000-0000-4000-8000-000000000194",
            workspaceIDs: []
        )
        let consumer = makeNodeRuntimeBrokerManager("node-runtime-advertisement-consumer", namespace: namespace)
        defer { consumer.stop() }
        let stream = try await consumer.observeAdvertiseStream(withObjectType: GnosticObjectType.timeline)
        let events = Task { () -> [AdvertiseEventSnapshot] in
            var events: [AdvertiseEventSnapshot] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await startNodeRuntimeBrokerManager(consumer)

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan())
        try await runtime.start()
        try await Task.sleep(for: .seconds(1))
        await runtime.shutdown()
        consumer.stop()
        events.cancel()

        #expect(await events.value.count == 1)
    }

    @Test("custom Workspace adapters advertise their own tool projection") @MainActor
    func customWorkspaceAdapterToolsAreAdvertised() async throws {
        let namespace = "node-runtime-custom-workspace-tools"
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000195")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000196")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000197")!
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000198")!),
            ascendants: [.init(id: ascendantID, name: "Atlas", defaultTimelineID: timelineID)],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)],
            workspaces: [.init(id: workspaceID, name: "Permissioned", uri: "echo://permissioned", kind: "permissioned-echo")]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.workspaces.register(kind: "permissioned-echo") { configuration, _ in
            ProjectedToolWorkspace(configuration: configuration)
        }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        defer { Task { @MainActor in await runtime.shutdown() } }
        try await runtime.start()

        let consumer = makeNodeRuntimeBrokerManager("custom-workspace-consumer", namespace: namespace)
        defer { consumer.stop() }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }
        try await startNodeRuntimeBrokerManager(consumer)
        await subscription.discover(using: consumer, timeout: .seconds(1))

        let workspace = try #require(await catalog.networkObjects().first {
            $0.objectType == GnosticObjectType.workspace && $0.objectID == workspaceID
        }?.workspace)
        #expect(workspace.tools.map(\.id) == ["permissioned_echo"])
        #expect(workspace.tools.allSatisfy { $0.requiresPermission })
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

        for _ in 0..<20 {
            if await Set(catalog.networkObjects().map(\.objectType)).count >= 3 { break }
            await subscription.discover(using: consumer, timeout: .milliseconds(200))
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await Set(catalog.networkObjects().map(\.objectType)) == Set([
            GnosticObjectType.ascendant,
            GnosticObjectType.timeline,
            GnosticObjectType.workspace,
        ]))

        let update = TimelineUpdateRequest(timelineID: manifest.timelines[0].id, title: "Renamed")
        let payload = String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
        _ = try await consumer.call(operation: TimelineManagementProvider.updateOperation, parameters: payload, timeout: .seconds(3))
        #expect(await runtime.timeline(id: manifest.timelines[0].id)?.title == "Renamed")
        await subscription.discover(using: consumer, timeout: .seconds(1))
        for _ in 0..<20 {
            if await catalog.networkObjects().first(where: { $0.objectID == manifest.timelines[0].id })?.name == "Renamed" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await catalog.networkObjects().first(where: { $0.objectID == manifest.timelines[0].id })?.name == "Renamed")
    }

    @Test("each backend identity is published from one runtime") @MainActor
    func twoBackendsPublishBothAscendants() async throws {
        let namespace = "node-runtime-two-backend-ascendants-\(UUID().uuidString.lowercased())"
        let firstAscendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000301")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000302")!
        let secondAscendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000303")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000304")!
        let runtime = try await NodeRuntime(plan: NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000305")!),
            ascendants: [
                .init(id: firstAscendantID, name: "First backend", defaultTimelineID: firstTimelineID),
                .init(id: secondAscendantID, name: "Second backend", defaultTimelineID: secondTimelineID),
            ],
            timelines: [
                .init(id: firstTimelineID, title: "First timeline", operatingAscendantID: firstAscendantID),
                .init(id: secondTimelineID, title: "Second timeline", operatingAscendantID: secondAscendantID),
            ]
        ).compileLaunchPlan())
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let consumer = makeNodeRuntimeBrokerManager("two-backend-ascendants-consumer", namespace: namespace)
        defer { consumer.stop() }
        try await startNodeRuntimeBrokerManager(consumer)
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }

        for _ in 0..<20 {
            await subscription.discover(using: consumer, timeout: .milliseconds(200))
            let ascendants = await catalog.networkObjects().filter { $0.objectType == GnosticObjectType.ascendant }
            if ascendants.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let ascendants = await catalog.networkObjects().filter { $0.objectType == GnosticObjectType.ascendant }
        #expect(Set(ascendants.map(\.objectID)) == Set([firstAscendantID, secondAscendantID]))
        #expect(Set(ascendants.map(\.providerID)).count == 1)
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

        for _ in 0..<30 where await runtime.workspaceReference(id: workspaceID)?.tools.isEmpty != false {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await runtime.workspaceReference(id: workspaceID)?.tools.first?.toolID == "existing_echo")
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
        #expect(await runtime.workspaceReference(id: workspaceID)?.tools.isEmpty == true)
        #expect(try await runtime.enabledToolIDs(for: timelineID).contains("remote_echo") == false)

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

        for _ in 0..<40 where await runtime.workspaceReference(id: workspaceID)?.tools.isEmpty != false {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await runtime.workspaceReference(id: workspaceID)?.tools.isEmpty == false)
        #expect(try await runtime.enabledToolIDs(for: timelineID).contains("remote_echo"))
    }

    @Test("an unambiguous discovered Workspace need not be predeclared in the manifest") @MainActor
    func resolvesDiscoveredWorkspaceOutsideManifest() async throws {
        let namespace = "node-runtime-dynamic-workspace"
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000217")!
        let runtime = try await NodeRuntime(plan: NodeManifest.empty(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace)
        ).compileLaunchPlan())
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let remote = try CommunicationManager(
            identity: Identity(name: "dynamic-workspace-provider"),
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
        let advertised = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://dynamic")!,
            location: .runtime,
            tools: [.custom(.init(id: "dynamic_echo", name: "Dynamic echo", description: "Echoes dynamically."))]
        )
        remote.publishAdvertise(try AdvertiseEvent.with(object: GnosticWorkspaceObject(workspace: advertised)))

        let resolved = try await runtime.resolveNetworkWorkspace(workspaceID: workspaceID, timeout: .seconds(2))

        #expect(resolved.id == workspaceID)
        #expect(await runtime.workspaceReference(id: workspaceID)?.tools.first?.toolID == "dynamic_echo")
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

    private func makeProviderIsolationManifest(
        namespace: String,
        nodeID: String,
        ascendantID: String,
        timelineID: UUID,
        profileID: String,
        profileModel: String
    ) throws -> NodeManifest {
        let node = try #require(UUID(uuidString: nodeID))
        let ascendant = try #require(UUID(uuidString: ascendantID))
        _ = try #require(UUID(uuidString: profileID))
        return NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: node),
            ascendants: [.init(id: ascendant, name: profileModel, defaultTimelineID: timelineID, backend: .init(kind: "positronic", settings: ["model": .string(profileModel), "provider": .string("stub")]))],
            timelines: [.init(id: timelineID, title: "\(profileModel) timeline", operatingAscendantID: ascendant)]
        )
    }

    private func providerIsolationContext(_ providerID: String) -> ObjectFilter {
        ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        ))
    }
}

@MainActor
private final class FixtureAscendantBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    private var storedTimelines: [AscendantBackendTimeline]
    private let cancellationProbe: AdapterCancellationProbe?
    private let creationProbe: AdapterCreationProbe?

    init(ascendant: NodeManifest.Ascendant, timelines: [NodeManifest.Timeline], cancellationProbe: AdapterCancellationProbe? = nil, creationProbe: AdapterCreationProbe? = nil) {
        let now = Date()
        self.cancellationProbe = cancellationProbe
        self.creationProbe = creationProbe
        identity = .init(id: ascendant.id, name: ascendant.name, description: ascendant.description, privateTimelineID: ascendant.defaultTimelineID, primaryWorkspaceID: nil, lastActiveAt: now, createdAt: now, updatedAt: now)
        storedTimelines = timelines.map { .init(id: $0.id, title: $0.title, attachedWorkspaceIDs: $0.attachments.map(\.workspaceID), ascendantID: ascendant.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now) }
    }

    func validateConfiguration() throws {}
    func operatedTimelines() async throws -> [AscendantBackendTimeline] { storedTimelines }
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        let createdID = creationProbe == nil ? id : UUID.makeVersion4()
        let timeline = AscendantBackendTimeline(id: createdID, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        storedTimelines.append(timeline)
        return timeline
    }
    func removeTimeline(id: UUID) async {
        storedTimelines.removeAll { $0.id == id }
        await creationProbe?.recordRemoval(id)
    }
    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let index = storedTimelines.firstIndex(where: { $0.id == id }) else { throw NodeRuntimeError.missingTimeline(id) }
        let current = storedTimelines[index]
        let renamed = AscendantBackendTimeline(id: current.id, title: title, attachedWorkspaceIDs: current.attachedWorkspaceIDs, ascendantID: current.ascendantID, isArchived: current.isArchived, isPrivate: current.isPrivate, createdAt: current.createdAt, updatedAt: Date())
        storedTimelines[index] = renamed
        return renamed
    }
    func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {}
    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {}
    func enabledToolIDs(for timelineID: UUID) async -> [String] { [] }
    func runTurn(_ request: AscendantBackendTurnRequest, updates: any AscendantBackendUpdateSink) async throws -> String {
        if let cancellationProbe { return try await cancellationProbe.run() }
        return "fixture: \(request.message)"
    }
    func cancel() async { await cancellationProbe?.cancel() }
    func shutdown() async {}
}

private actor AdapterCancellationProbe {
    private var started = false
    private var cancelled = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    var wasCancelled: Bool { cancelled }

    func run() async throws -> String {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { release = $0 }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func cancel() {
        cancelled = true
        release?.resume()
        release = nil
    }
}

private actor AdapterCreationProbe {
    private(set) var removedIDs: [UUID] = []
    func recordRemoval(_ id: UUID) { removedIDs.append(id) }
}

private final class NodeToolCaptureLanguageModel: LanguageModel, @unchecked Sendable {
    private let capture = ToolNameCapture()

    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func toolNames() async -> Set<String> { await capture.names }

    func chatStream(
        messages _: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await capture.record(tools ?? [])
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMStreamChunk(
                id: "capture",
                model: "capture",
                choices: [.init(index: 0, delta: .init(content: "ready"), finishReason: "stop")]
            ))
            continuation.finish()
        }
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }

    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}
    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { "ready" }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { "capture" }
    func evaluateRecallPerformance(
        transcript _: String,
        recalledMemories _: [Memory]
    ) async throws -> [String: Double] { [:] }
    func fetchAvailableModels() async throws -> [String]? { nil }

    private actor ToolNameCapture {
        private(set) var names: Set<String> = []

        func record(_ tools: [LLMToolDefinition]) {
            names = Set(tools.map(\.name))
        }
    }
}

private struct ProjectedToolWorkspace: Workspace, Sendable {
    let reference: WorkspaceReference
    var id: UUID { reference.id }

    init(configuration: NodeManifest.Workspace) {
        reference = WorkspaceReference(
            id: configuration.id,
            uri: WorkspaceURI(parsing: configuration.uri)!,
            location: .runtime,
            tools: [.custom(.init(
                id: "permissioned_echo",
                name: "Permissioned echo",
                description: "Echoes after approval.",
                requiresPermission: true
            ))]
        )
    }

    func listTools() async throws -> [ToolReference] { reference.tools }
    func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult { .success("ok") }
    func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    func listFiles(path _: String) async throws -> [String] { throw WorkspaceError.toolExecutionNotSupported }
    func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    func healthCheck() async -> Bool { true }
}

private struct CancellationWorkspace: Workspace, Sendable {
    let reference: WorkspaceReference
    var id: UUID { reference.id }

    func listTools() async throws -> [ToolReference] { reference.tools }
    func executeTool(id _: String, parameters _: [String: AnyCodable]) async throws -> ToolResult {
        throw CancellationError()
    }
    func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    func listFiles(path _: String) async throws -> [String] { throw WorkspaceError.toolExecutionNotSupported }
    func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    func healthCheck() async -> Bool { true }
}

private final class ProviderIsolationLanguageModel: LanguageModel, @unchecked Sendable {
    let response: String
    private let state = InvocationState()

    init(response: String) {
        self.response = response
    }

    var invocationCount: Int {
        get async { await state.count }
    }

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func chatStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await state.recordInvocation()
        let response = response
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMStreamChunk(
                id: response,
                model: response,
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: response),
                    finishReason: "stop"
                )]
            ))
            continuation.finish()
        }
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier
        )
    }

    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}
    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { response }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { response }
    func evaluateRecallPerformance(
        transcript _: String,
        recalledMemories _: [Memory]
    ) async throws -> [String: Double] { [:] }
    func fetchAvailableModels() async throws -> [String]? { [response] }

    private actor InvocationState {
        private(set) var count = 0

        func recordInvocation() {
            count += 1
        }
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
