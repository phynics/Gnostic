// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticClient
import GnosticCore
import Testing

@testable import GnosticCLI

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Consumer to two owner process MQTT integration", .serialized, .timeLimit(.minutes(1)))
struct TwoNodeMQTTIntegrationTests {
    @Test("consumer runs Turns against two live Timeline owner processes")
    @MainActor
    func consumerRunsTurnsAgainstTwoLiveTimelineOwners() async throws {
        let serveBinary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_SERVE_BINARY"])
        let agentFixture = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"])
        let namespace = "two-node-\(UUID().uuidString.lowercased())"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-two-node-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let first = try await launchNode(
            name: "first",
            namespace: namespace,
            serveBinary: serveBinary,
            agentFixture: agentFixture,
            scratch: scratch
        )
        let second: NodeProcess
        do {
            second = try await launchNode(
                name: "second",
                namespace: namespace,
                serveBinary: serveBinary,
                agentFixture: agentFixture,
                scratch: scratch
            )
        } catch {
            await first.shutdown()
            throw error
        }

        do {
            try await runConsumer(namespace: namespace, nodes: [first, second])
        } catch {
            await second.shutdown()
            await first.shutdown()
            throw error
        }

        await second.shutdown()
        await first.shutdown()
    }

    @Test("abrupt owner loss ends the in-flight Turn and transfers no authority")
    @MainActor
    func abruptOwnerLossEndsTurnWithoutAuthorityTransfer() async throws {
        let serveBinary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_SERVE_BINARY"])
        let agentFixture = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"])
        let namespace = "peer-loss-\(UUID().uuidString.lowercased())"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-peer-loss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let session = try GnosticConsumerSession(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(3)
        )
        do {
            try await session.start()
        } catch {
            await session.stop()
            throw error
        }

        let survivor = try await launchNode(
            name: "survivor",
            namespace: namespace,
            serveBinary: serveBinary,
            agentFixture: agentFixture,
            scratch: scratch
        )
        let promptStarted = scratch.appendingPathComponent("owner-prompt-started")
        let owner: NodeProcess
        do {
            owner = try await launchNode(
                name: "owner",
                namespace: namespace,
                serveBinary: serveBinary,
                agentFixture: agentFixture,
                scratch: scratch,
                fixtureEnvironment: ["GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE": promptStarted.path]
            )
        } catch {
            await session.stop()
            await survivor.shutdown()
            throw error
        }

        do {
            let advertisementClock = ContinuousClock()
            let advertisementDeadline = advertisementClock.now + .seconds(5)
            var advertised: NetworkCatalogEntry?
            while advertisementClock.now < advertisementDeadline {
                advertised = await session.networkObjects().first {
                    $0.objectType == GnosticObjectType.timeline && $0.objectID == owner.timelineID
                }
                if advertised != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let ownerProvider = try #require(advertised?.providerID)
            let client = try session.turnClient(timeout: .seconds(3), promptTimeout: .seconds(20))
            let clientTurnID = "peer-loss-turn"
            let updates = try await client.updates(
                for: clientTurnID,
                timelineID: owner.timelineID,
                providerID: ownerProvider
            )
            let collector = PeerLossUpdateCollector()
            let observation = Task { @MainActor in
                for await update in updates {
                    collector.received.append(update)
                    if update.terminal { break }
                }
            }
            defer { observation.cancel() }
            let run = Task { @MainActor in
                try await client.run(
                    message: "[fixture:wait]",
                    timelineID: owner.timelineID,
                    clientTurnID: clientTurnID,
                    providerID: ownerProvider
                )
            }

            try await waitForFile(promptStarted, timeout: .seconds(10))
            let clock = ContinuousClock()
            let started = clock.now
            _ = kill(owner.process.processIdentifier, SIGKILL)
            owner.process.waitUntilExit()
            if let fixturePIDURL = owner.fixturePIDURL {
                await stopFixtureProcess(at: fixturePIDURL)
            }

            var runFailure: (any Error)?
            do {
                _ = try await run.value
                Issue.record("The Turn succeeded after its owner was killed.")
            } catch {
                runFailure = error
            }
            let elapsed = clock.now - started
            #expect(elapsed < .seconds(8), "The Turn waited \(elapsed) for a dead owner.")
            let failureReason = (runFailure as? GnosticTurnClientError)?.reasonCode
            #expect(
                failureReason == "providerOffline" || failureReason == "transportFailure",
                Comment(rawValue: "Unexpected failure: \(String(describing: runFailure))")
            )

            let observationClock = ContinuousClock()
            let observationDeadline = observationClock.now + .seconds(10)
            while observationClock.now < observationDeadline,
                  collector.received.last?.terminal != true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let terminal = try #require(collector.received.last)
            #expect(terminal.terminal == true)
            #expect(terminal.reasonCode == "providerOffline")

            try await session.discover(timeout: .seconds(2))
            let remaining = await session.networkObjects().filter { $0.objectID == owner.timelineID }
            #expect(remaining.isEmpty, "A surviving peer took authority for the lost Timeline.")
            let survivorTimeline = await session.networkObjects().contains {
                $0.objectType == GnosticObjectType.timeline && $0.objectID == survivor.timelineID
            }
            #expect(survivorTimeline)
        } catch {
            await session.stop()
            await owner.shutdown()
            await survivor.shutdown()
            throw error
        }
        await session.stop()
        await owner.shutdown()
        await survivor.shutdown()
    }

    @Test("Node A ACP Runtime reaches Node B Workspace through the gateway and honors owner revocation")
    @MainActor
    func runtimeInvokesRemoteWorkspaceAndOwnerRevocationBlocksNextCall() async throws {
        let serveBinary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_SERVE_BINARY"])
        let agentFixture = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"])
        let namespace = "peer-workspace-\(UUID().uuidString.lowercased())"
        let workspaceID = UUID()
        let workspaceURI = "workspace://peer-workspace-\(workspaceID.uuidString.lowercased())"
        let timelineID = UUID()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-peer-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let trace = WorkspaceScenarioTrace()
        trace.record("setup.begin", [
            "timelineID": timelineID.uuidString.lowercased(),
            "workspaceID": workspaceID.uuidString.lowercased(),
            "brokerNamespace": namespace,
        ])
        var completed = false
        defer {
            if completed {
                try? FileManager.default.removeItem(at: scratch)
            } else {
                if let artifact = try? trace.persist(from: scratch) {
                    print("Two-Node Workspace diagnostics saved under \(artifact.path)")
                } else {
                    print("Two-Node Workspace diagnostics could not be copied; temporary path retained at \(scratch.path)")
                }
            }
        }

        trace.record("workspace-owner.starting")
        let workspaceNode: WorkspaceNodeProcess
        do {
            workspaceNode = try await launchWorkspaceNode(
                namespace: namespace,
                scratch: scratch,
                workspaceID: workspaceID,
                workspaceURI: workspaceURI,
                serveBinary: serveBinary,
                agentFixture: agentFixture
            )
            trace.record("workspace-owner.started", [
                "pid": String(workspaceNode.process.process.processIdentifier),
            ])
        } catch {
            trace.recordFailure(error)
            throw error
        }
        let session = try GnosticConsumerSession(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(3)
        )
        do {
            trace.record("consumer.construct")
            try await session.start()
            trace.record("consumer.discover.workspace-owner-before-runtime-owner")
            try await session.discover(timeout: .seconds(3))
            let cachedWorkspace = await session.networkObjects().first {
                $0.objectType == GnosticObjectType.workspace && $0.objectID == workspaceID
            }
            trace.record("consumer.workspace-cached-before-runtime-owner", [
                "providerID": cachedWorkspace?.providerID ?? "missing",
            ])
            try #require(cachedWorkspace != nil)
        } catch {
            trace.recordFailure(error)
            await session.stop()
            await workspaceNode.process.shutdown()
            throw error
        }
        let owner: NodeProcess
        do {
            trace.record("runtime-owner.starting")
            owner = try await launchNode(
                name: "runtime-owner",
                namespace: namespace,
                serveBinary: serveBinary,
                agentFixture: agentFixture,
                scratch: scratch,
                timelineID: timelineID
            )
            trace.record("runtime-owner.started", ["pid": String(owner.process.processIdentifier)])
        } catch {
            trace.recordFailure(error)
            await session.stop()
            await workspaceNode.process.shutdown()
            throw error
        }
        do {
            try await runGatewayRevocationScenario(
                namespace: namespace,
                timelineID: timelineID,
                workspaceID: workspaceID,
                workspaceNode: workspaceNode,
                session: session,
                trace: trace
            )
        } catch {
            trace.recordFailure(error)
            await session.stop()
            await owner.shutdown()
            await workspaceNode.process.shutdown()
            throw error
        }

        await owner.shutdown()
        await workspaceNode.process.shutdown()
        completed = true
    }

    @MainActor
    private func runGatewayRevocationScenario(
        namespace: String,
        timelineID: UUID,
        workspaceID: UUID,
        workspaceNode: WorkspaceNodeProcess,
        session: GnosticConsumerSession,
        trace: WorkspaceScenarioTrace
    ) async throws {
        do {
            trace.record("consumer.discover")
            try await session.discover(timeout: .seconds(3))
            trace.record("consumer.resolve-timeline")
            let timeline = await session.networkObjects().first {
                $0.objectType == GnosticObjectType.timeline
                    && $0.objectID == timelineID
            }
            let providerID = try #require(timeline?.providerID)
            trace.record("consumer.resolve-workspace")
            let networkObjects = await session.networkObjects()
            let workspaceProviderID = try #require(networkObjects.first {
                $0.objectType == GnosticObjectType.workspace && $0.objectID == workspaceID
            }?.providerID)
            trace.record("consumer.targets-resolved", [
                "timelineProviderID": providerID,
                "workspaceProviderID": workspaceProviderID,
            ])
            let client = try session.turnClient(timeout: .seconds(3), promptTimeout: .seconds(8))
            let workspaceClient = try session.workspaceClient(timeout: .seconds(5))
            trace.record("workspace.attach.request", [
                "timelineProviderID": providerID,
                "workspaceProviderID": workspaceProviderID,
                "operation": WorkspaceOpsProvider.attachOperation,
            ])
            try await workspaceClient.attach(
                workspaceID: workspaceID,
                to: timelineID,
                approved: true,
                providerID: providerID
            )
            trace.record("workspace.attach.returned")
            var attachmentAdvertisementReady = false
            for attempt in 1...12 {
                try await session.discover(timeout: .milliseconds(250))
                let timelineAdvertisement = await session.networkObjects().first {
                    $0.objectType == GnosticObjectType.timeline
                        && $0.objectID == timelineID
                        && $0.providerID == providerID
                }
                let attachedWorkspaceIDs: Set<UUID>
                if case let .array(values)? = timelineAdvertisement?.knownProperties["attachedWorkspaceIDs"] {
                    attachedWorkspaceIDs = Set(values.compactMap { value in
                        guard case let .string(id) = value else { return nil }
                        return UUID(uuidString: id)
                    })
                } else {
                    attachedWorkspaceIDs = []
                }
                attachmentAdvertisementReady = attachedWorkspaceIDs.contains(workspaceID)
                trace.record("workspace.attach.advertisement-poll", [
                    "attempt": String(attempt),
                    "timelineProviderID": timelineAdvertisement?.providerID ?? "missing",
                    "workspaceAdvertised": String(attachmentAdvertisementReady),
                ])
                if attachmentAdvertisementReady { break }
            }
            trace.record("workspace.attach.advertisement-ready", [
                "ready": String(attachmentAdvertisementReady),
                "meaning": "consumer-visible-catalog-only",
            ])
            try #require(attachmentAdvertisementReady)

            let beforeStatus = await workspaceClient.effectiveStatus(workspaceID: workspaceID)
            trace.record("workspace.owner-status.before-revocation.returned", [
                "effectiveStatus": beforeStatus.rawValue,
                "source": "owner-advertisement",
            ])
            try #require(beforeStatus == .available)

            let first = try await runTurnApprovingWorkspacePermission(
                client: client,
                timelineID: timelineID,
                clientTurnID: "peer-workspace-first",
                providerID: providerID,
                message: "[fixture:workspace-tool]",
                trace: trace,
                stagePrefix: "gateway.first"
            )
            let firstResultMatched = first.text.contains("remote workspace result: fixture")
            trace.record("gateway.first.result-checked", ["expectedFixtureResult": String(firstResultMatched)])
            try #require(firstResultMatched)
            let firstInvocationCount = try workspaceNode.invocationCount()
            trace.record("gateway.first.asserted", ["providerInvocationCount": String(firstInvocationCount)])
            try #require(firstInvocationCount == 1)

            try await assertThirdPeerCannotForgeWorkspaceApproval(
                namespace: namespace,
                timelineID: timelineID,
                workspaceID: workspaceID,
                providerID: workspaceProviderID,
                workspaceNode: workspaceNode,
                trace: trace
            )

            trace.record("workspace.owner-health-revocation.request")
            try workspaceNode.revoke()
            trace.record("workspace.owner-health-revocation.written")
            let rejected = try await runTurnApprovingWorkspacePermission(
                client: client,
                timelineID: timelineID,
                clientTurnID: "peer-workspace-revocation-transition",
                providerID: providerID,
                message: "[fixture:workspace-tool-rejected]",
                trace: trace,
                stagePrefix: "gateway.revocation-transition"
            )
            let transitionRejected = rejected.text.contains("workspace call rejected (-32003)")
            trace.record("gateway.revocation-transition.result-checked", ["rejected": String(transitionRejected)])
            try #require(transitionRejected)
            let afterTransitionInvocationCount = try workspaceNode.invocationCount()
            trace.record("gateway.revocation-transition.asserted", [
                "providerInvocationCount": String(afterTransitionInvocationCount),
            ])
            try #require(afterTransitionInvocationCount == 1)
            trace.record("workspace.owner-registry-status.rediscovery.request")
            try await session.discover(timeout: .seconds(3))
            let afterStatus = await workspaceClient.effectiveStatus(workspaceID: workspaceID)
            trace.record("workspace.owner-registry-status.rediscovery.returned", [
                "effectiveStatus": afterStatus.rawValue,
                "source": "Node B authoritative registry projection",
            ])
            try #require(afterStatus == .unavailable)
            trace.record("workspace.owner-registry-status.unavailable.asserted")

            let rejectedByEffectiveStatus = try await runTurnApprovingWorkspacePermission(
                client: client,
                timelineID: timelineID,
                clientTurnID: "peer-workspace-revoked-status",
                providerID: providerID,
                message: "[fixture:workspace-tool-rejected]",
                trace: trace,
                stagePrefix: "gateway.revoked-status"
            )
            let effectiveStatusRejected = rejectedByEffectiveStatus.text.contains("workspace call rejected (-32003)")
            trace.record("gateway.revoked-status.result-checked", ["rejected": String(effectiveStatusRejected)])
            try #require(effectiveStatusRejected)
            let afterStatusInvocationCount = try workspaceNode.invocationCount()
            trace.record("gateway.revoked-status.asserted", [
                "providerInvocationCount": String(afterStatusInvocationCount),
            ])
            try #require(afterStatusInvocationCount == 1)
            trace.record("consumer.stop")
            await session.stop()
        } catch {
            trace.recordFailure(error)
            await session.stop()
            throw error
        }
    }

    @MainActor
    private func assertThirdPeerCannotForgeWorkspaceApproval(
        namespace: String,
        timelineID: UUID,
        workspaceID: UUID,
        providerID: String,
        workspaceNode: WorkspaceNodeProcess,
        trace: WorkspaceScenarioTrace
    ) async throws {
        trace.record("third-peer.construct")
        let peer = try GnosticConsumerSession(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(3)
        )
        do {
            trace.record("third-peer.start")
            try await peer.start()
            trace.record("third-peer.discover")
            try await peer.discover(timeout: .seconds(3))
            let workspaceClient = try peer.workspaceClient(timeout: .seconds(5))
            trace.record("third-peer.forged-invocation.request", [
                "providerID": providerID,
                "timelineID": timelineID.uuidString.lowercased(),
                "workspaceID": workspaceID.uuidString.lowercased(),
                "operation": GnosticWorkspaceProtocol.invocationOperation,
            ])
            do {
                _ = try await workspaceClient.invoke(
                    timelineID: timelineID,
                    workspaceID: workspaceID,
                    toolID: "search",
                    arguments: ["query": .string("forged")],
                    permissionApproved: true,
                    providerID: providerID
                )
                trace.record("third-peer.forged-invocation.unexpectedly-returned")
                Issue.record("a third caller must not authorize itself with a Timeline ID and approval flag")
                throw TwoNodeIntegrationError.thirdPeerInvocationSucceeded
            } catch let error as GnosticWorkspaceClientError {
                trace.record("third-peer.forged-invocation.owner-handler-rejected", ["reasonCode": error.reasonCode])
                try #require(error.reasonCode == "workspaceNotAttached")
            }
            let invocationCount = try workspaceNode.invocationCount()
            trace.record("third-peer.provider-count.asserted", ["providerInvocationCount": String(invocationCount)])
            try #require(invocationCount == 1)
            trace.record("third-peer.stop")
            await peer.stop()
        } catch {
            trace.recordFailure(error)
            await peer.stop()
            throw error
        }
    }

    @MainActor
    private func runTurnApprovingWorkspacePermission(
        client: GnosticTurnClient,
        timelineID: UUID,
        clientTurnID: String,
        providerID: String,
        message: String,
        trace: WorkspaceScenarioTrace,
        stagePrefix: String
    ) async throws -> AscendantTurnResult {
        trace.record("\(stagePrefix).updates.subscribe", [
            "timelineProviderID": providerID,
            "clientTurnID": clientTurnID,
        ])
        let updates = try await client.updates(for: clientTurnID, timelineID: timelineID, providerID: providerID)
        trace.record("\(stagePrefix).updates.subscribed")
        let permissionResponder = Task { () async throws -> Bool in
            var receivedAndAnsweredPermission = false
            for await update in updates {
                trace.record("\(stagePrefix).update.received", [
                    "clientTurnID": clientTurnID,
                    "sequence": String(update.sequence),
                    "kind": update.kind,
                    "terminal": String(update.terminal),
                    "hasPermissionState": String(update.permissionState != nil),
                    "permissionStatus": update.permissionState?.status ?? "",
                    "reasonCode": update.reasonCode ?? "",
                    "statusCode": update.statusCode.map { String($0) } ?? "",
                ])
                guard let permission = update.permissionState, permission.status == "pending" else { continue }
                trace.record("\(stagePrefix).permission.pending", [
                    "clientTurnID": clientTurnID,
                    "correlationPresent": String(!permission.correlationID.isEmpty),
                ])
                do {
                    try client.respond(
                        to: AscendantPermissionResponse(
                            correlationID: permission.correlationID,
                            timelineID: timelineID,
                            clientTurnID: clientTurnID,
                            approved: true
                        ),
                        providerID: providerID
                    )
                } catch {
                    trace.recordFailure(error)
                    throw error
                }
                trace.record("\(stagePrefix).permission.response-published", ["clientTurnID": clientTurnID])
                receivedAndAnsweredPermission = true
            }
            trace.record("\(stagePrefix).updates.finished")
            return receivedAndAnsweredPermission
        }
        trace.record("\(stagePrefix).run.request", [
            "timelineProviderID": providerID,
            "clientTurnID": clientTurnID,
        ])
        let result = try await client.run(
            message: message,
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            providerID: providerID
        )
        trace.record("\(stagePrefix).run.returned", ["clientTurnID": clientTurnID])
        trace.record("\(stagePrefix).permission-responder.join")
        try #require(try await permissionResponder.value)
        trace.record("\(stagePrefix).permission.required-event-asserted")
        trace.record("\(stagePrefix).completed")
        return result
    }

    @MainActor
    private func runConsumer(namespace: String, nodes: [NodeProcess]) async throws {
        let session = try GnosticConsumerSession(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(3)
        )
        do {
            try await session.start()
            let client = try session.turnClient(timeout: .seconds(3), promptTimeout: .seconds(8))

            for node in nodes {
                let message = "hello \(node.name)"
                let clientTurnID = "turn-\(node.name)"
                let updates = try await client.updates(for: clientTurnID, timelineID: node.timelineID)
                let observation = Task {
                    var received: [AscendantTurnUpdate] = []
                    for await update in updates {
                        received.append(update)
                        if update.terminal { break }
                    }
                    return received
                }

                do {
                    let result = try await client.run(
                        message: message,
                        timelineID: node.timelineID,
                        clientTurnID: clientTurnID
                    )
                    let received = await withTaskCancellationHandler {
                        await observation.value
                    } onCancel: {
                        observation.cancel()
                    }

                    #expect(result.text == "fixture reply: \(message)")
                    #expect(received.map(\.text).compactMap { $0 }.joined() == "fixture reply: \(message)")
                    #expect(received.last?.kind == AscendantTurnUpdateKind.completion.rawValue)
                    #expect(received.last?.terminal == true)
                } catch {
                    observation.cancel()
                    await session.stop()
                    _ = await observation.value
                    throw error
                }
            }
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @MainActor
    private func launchNode(
        name: String,
        namespace: String,
        serveBinary: String,
        agentFixture: String,
        scratch: URL,
        timelineID requestedTimelineID: UUID? = nil,
        fixtureEnvironment extraFixtureEnvironment: [String: String] = [:]
    ) async throws -> NodeProcess {
        let configDirectory = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let store = CLIConfigurationStore(baseDirectory: configDirectory, environment: [:])
        _ = try store.initializeManifest()
        let manifest = try store.loadManifest()
        let timelineID: UUID
        if let requestedTimelineID {
            timelineID = requestedTimelineID
        } else {
            timelineID = try #require(manifest.timelines.first?.id)
        }
        let fixtureState = configDirectory.appendingPathComponent("fixture-sessions.json")
        try store.mutateManifest { manifest in
            let fixturePID = configDirectory.appendingPathComponent("fixture-process.pid")
            var fixtureEnvironment = [
                "GNOSTIC_ACP_FIXTURE_STATE": fixtureState.path,
                "GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE": fixturePID.path,
                "GNOSTIC_ACP_FIXTURE_MCP_DIAGNOSTICS_FILE": requestedTimelineID == nil
                    ? ""
                    : configDirectory.appendingPathComponent("mcp-diagnostics.jsonl").path,
                "GNOSTIC_ACP_FIXTURE_EXPECTED_WORKSPACE_TOOL_COUNT": requestedTimelineID == nil ? "1" : "17",
                "GNOSTIC_ACP_FIXTURE_MCP": requestedTimelineID == nil ? "0" : "1",
                "GNOSTIC_ACP_FIXTURE_WORKSPACE_TOOL_SUFFIX": requestedTimelineID == nil ? "" : "__search",
            ]
            fixtureEnvironment.merge(extraFixtureEnvironment) { _, new in new }
            manifest.ascendants[0].backend.settings["command"] = .string("node")
            manifest.ascendants[0].backend.settings["args"] = .string(try jsonString([agentFixture]))
            manifest.ascendants[0].backend.settings["env"] = .string(try jsonString(fixtureEnvironment))
            if let requestedTimelineID {
                manifest.timelines[0].id = requestedTimelineID
                manifest.ascendants[0].defaultTimelineID = requestedTimelineID
            }
        }

        let logURL = configDirectory.appendingPathComponent("serve.log")
        #expect(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: serveBinary)
        process.arguments = [
            "serve", "--config", store.path().path,
            "--host", "127.0.0.1", "--port", "1883", "--namespace", namespace,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["GNOSTIC_STATE_HOME"] = configDirectory.appendingPathComponent("state", isDirectory: true).path
        environment["GNOSTIC_TEST_WORKSPACE_FIXTURE"] = nil
        environment["GNOSTIC_TEST_WORKSPACE_HEALTH_FILE"] = nil
        environment["GNOSTIC_TEST_WORKSPACE_INVOCATIONS_FILE"] = nil
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            try? log.close()
            throw error
        }

        let node = NodeProcess(
            name: name,
            timelineID: timelineID,
            process: process,
            log: log,
            fixturePIDURL: configDirectory.appendingPathComponent("fixture-process.pid")
        )
        do {
            var online = false
            for _ in 0..<100 {
                try log.synchronize()
                let output = try String(contentsOf: logURL, encoding: .utf8)
                if output.contains("advertised objects"),
                   output.contains("timeline=\(timelineID.uuidString.lowercased())") {
                    online = true
                    break
                }
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let output = try String(contentsOf: logURL, encoding: .utf8)
            #expect(online, Comment(rawValue: output))
            guard online else { throw TwoNodeIntegrationError.nodeFailedToStart(name) }
            return node
        } catch {
            await node.shutdown()
            throw error
        }
    }

    @MainActor
    private func launchWorkspaceNode(
        namespace: String,
        scratch: URL,
        workspaceID: UUID,
        workspaceURI: String,
        serveBinary: String,
        agentFixture: String
    ) async throws -> WorkspaceNodeProcess {
        let configDirectory = scratch.appendingPathComponent("workspace-owner", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let store = CLIConfigurationStore(baseDirectory: configDirectory, environment: [:])
        _ = try store.initializeManifest()
        try store.mutateManifest { manifest in
            let fixtureState = configDirectory.appendingPathComponent("fixture-sessions.json")
            let fixturePID = configDirectory.appendingPathComponent("fixture-process.pid")
            let fixtureEnvironment = [
                "GNOSTIC_ACP_FIXTURE_STATE": fixtureState.path,
                "GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE": fixturePID.path,
            ]
            manifest.ascendants[0].backend.settings["command"] = .string("node")
            manifest.ascendants[0].backend.settings["args"] = .string(try jsonString([agentFixture]))
            manifest.ascendants[0].backend.settings["env"] = .string(try jsonString(fixtureEnvironment))
            manifest.workspaces = [NodeManifest.Workspace(
                id: workspaceID,
                name: "Remote revocation fixture",
                uri: workspaceURI,
                kind: "test-revocable-peer"
            )]
        }

        let healthURL = configDirectory.appendingPathComponent("workspace-health.txt")
        let invocationURL = configDirectory.appendingPathComponent("workspace-invocations.txt")
        try "available".write(to: healthURL, atomically: true, encoding: .utf8)
        try "0".write(to: invocationURL, atomically: true, encoding: .utf8)
        let logURL = configDirectory.appendingPathComponent("serve.log")
        #expect(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: serveBinary)
        process.arguments = [
            "serve", "--config", store.path().path,
            "--host", "127.0.0.1", "--port", "1883", "--namespace", namespace,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["GNOSTIC_STATE_HOME"] = configDirectory.appendingPathComponent("state", isDirectory: true).path
        environment["GNOSTIC_TEST_WORKSPACE_FIXTURE"] = "revocable-peer"
        environment["GNOSTIC_TEST_WORKSPACE_HEALTH_FILE"] = healthURL.path
        environment["GNOSTIC_TEST_WORKSPACE_INVOCATIONS_FILE"] = invocationURL.path
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            try? log.close()
            throw error
        }

        let node = NodeProcess(
            name: "workspace-owner",
            timelineID: UUID(),
            process: process,
            log: log,
            fixturePIDURL: configDirectory.appendingPathComponent("fixture-process.pid")
        )
        do {
            var online = false
            for _ in 0..<100 {
                try log.synchronize()
                let output = try String(contentsOf: logURL, encoding: .utf8)
                if output.contains("advertised objects") {
                    online = true
                    break
                }
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let output = try String(contentsOf: logURL, encoding: .utf8)
            #expect(online, Comment(rawValue: output))
            guard online else { throw TwoNodeIntegrationError.nodeFailedToStart("workspace-owner") }
            return WorkspaceNodeProcess(process: node, healthURL: healthURL, invocationURL: invocationURL)
        } catch {
            await node.shutdown()
            throw error
        }
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }
}

@MainActor
private struct NodeProcess {
    let name: String
    let timelineID: UUID
    let process: Process
    let log: FileHandle

    let fixturePIDURL: URL?

    func shutdown() async {
        if process.isRunning {
            process.terminate()
            for _ in 0..<50 {
                guard process.isRunning else { break }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        if let fixturePIDURL { await stopFixtureProcess(at: fixturePIDURL) }
        try? log.close()
    }
}

@MainActor
private struct WorkspaceNodeProcess {
    let process: NodeProcess
    let healthURL: URL
    let invocationURL: URL

    func revoke() throws {
        try "revoked".write(to: healthURL, atomically: true, encoding: .utf8)
    }

    func invocationCount() throws -> Int {
        Int(try String(contentsOf: invocationURL, encoding: .utf8)) ?? -1
    }
}

@MainActor
private final class WorkspaceScenarioTrace {
    private struct Event: Encodable {
        let elapsedMilliseconds: Int
        let stage: String
        let fields: [String: String]
    }

    private struct Context: Encodable {
        let failureType: String
        let events: [Event]
        let copiedFiles: [String]
        let unavailableFiles: [String]
    }

    private let startedAt = Date()
    private var events: [Event] = []
    private var failureType = "unknown"

    func record(_ stage: String, _ fields: [String: String] = [:]) {
        events.append(Event(
            elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            stage: stage,
            fields: fields
        ))
    }

    func recordFailure(_ error: Error) {
        failureType = String(reflecting: type(of: error))
        record("scenario.failed", ["errorType": failureType])
    }

    func persist(from scratch: URL) throws -> URL {
        let artifact = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".testing", isDirectory: true)
            .appendingPathComponent("two-node-workspace", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)

        let allowlistedFiles: [(source: String, destination: String)] = [
            ("runtime-owner/serve.log", "runtime-owner-serve.log"),
            ("runtime-owner/mcp-diagnostics.jsonl", "runtime-owner-mcp-diagnostics.jsonl"),
            ("workspace-owner/serve.log", "workspace-owner-serve.log"),
            ("workspace-owner/workspace-invocations.txt", "workspace-invocations.txt"),
            ("workspace-owner/workspace-health.txt", "workspace-health.txt"),
        ]
        var copiedFiles: [String] = []
        var unavailableFiles: [String] = []
        for file in allowlistedFiles {
            let source = scratch.appendingPathComponent(file.source)
            let destination = artifact.appendingPathComponent(file.destination)
            guard FileManager.default.fileExists(atPath: source.path) else {
                unavailableFiles.append(file.source)
                continue
            }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                copiedFiles.append(file.destination)
            } catch {
                unavailableFiles.append(file.source)
            }
        }

        let context = Context(
            failureType: failureType,
            events: events,
            copiedFiles: copiedFiles,
            unavailableFiles: unavailableFiles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(context)
        try data.write(to: artifact.appendingPathComponent("context.json"), options: .atomic)
        return artifact
    }
}

@MainActor
private final class PeerLossUpdateCollector {
    var received: [AscendantTurnUpdate] = []
}

@MainActor
private func waitForFile(_ url: URL, timeout: Duration) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for \(url.path).")
    throw TwoNodeIntegrationError.nodeFailedToStart("fixture prompt start")
}

@MainActor
private func stopFixtureProcess(at pidURL: URL) async {
    guard FileManager.default.fileExists(atPath: pidURL.path) else { return }
    guard let rawPID = try? String(contentsOf: pidURL, encoding: .utf8)
        .split(whereSeparator: \.isNewline).first,
          let pid = Int32(String(rawPID)) else {
        Issue.record("ACP fixture PID file is present but invalid: \(pidURL.path)")
        return
    }
    guard fixtureProcessIsRunning(pid: pid) else { return }

    _ = kill(pid, SIGTERM)
    for _ in 0..<50 {
        guard fixtureProcessIsRunning(pid: pid) else { return }
        if Task.isCancelled { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    _ = kill(pid, SIGKILL)
    let stopped = await Task.detached {
        for _ in 0..<50 {
            guard fixtureProcessIsRunning(pid: pid) else { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !fixtureProcessIsRunning(pid: pid)
    }.value
    if !stopped {
        Issue.record("ACP fixture process \(pid) remained alive after forced cleanup.")
    }
}

private func fixtureProcessIsRunning(pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

private enum TwoNodeIntegrationError: Error {
    case nodeFailedToStart(String)
    case thirdPeerInvocationSucceeded
}
