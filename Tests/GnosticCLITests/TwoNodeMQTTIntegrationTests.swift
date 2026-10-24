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
        let owner: NodeProcess
        do {
            trace.record("runtime-owner.starting")
            owner = try await launchNode(
                name: "runtime-owner",
                namespace: namespace,
                serveBinary: serveBinary,
                agentFixture: agentFixture,
                scratch: scratch,
                timelineID: timelineID,
                workspaceID: workspaceID,
                workspaceURI: workspaceURI
            )
            trace.record("runtime-owner.started", ["pid": String(owner.process.processIdentifier)])
        } catch {
            trace.recordFailure(error)
            await workspaceNode.process.shutdown()
            throw error
        }
        do {
            try await runGatewayRevocationScenario(
                namespace: namespace,
                timelineID: timelineID,
                workspaceID: workspaceID,
                workspaceNode: workspaceNode,
                trace: trace
            )
        } catch {
            trace.recordFailure(error)
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
        trace: WorkspaceScenarioTrace
    ) async throws {
        trace.record("consumer.construct")
        let session = try GnosticConsumerSession(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(3)
        )
        do {
            trace.record("consumer.start")
            try await session.start()
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
            let diagnostics = try session.diagnosticsClient(timeout: .seconds(5))
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
            let timelineAfterAttach = await session.networkObjects().first {
                $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
            }
            let attachedWorkspaceIDs: String
            if case let .array(values)? = timelineAfterAttach?.knownProperties["attachedWorkspaceIDs"] {
                attachedWorkspaceIDs = values.compactMap { value in
                    guard case let .string(id) = value else { return nil }
                    return id
                }.joined(separator: ",")
            } else {
                attachedWorkspaceIDs = "missing"
            }
            trace.record("workspace.attach.catalog-snapshot", [
                "timelineProviderID": timelineAfterAttach?.providerID ?? "missing",
                "attachedWorkspaceIDs": attachedWorkspaceIDs,
            ])

            trace.record("workspace.owner-status.before-revocation.request", ["providerID": workspaceProviderID])
            let beforeRevocation = try await diagnostics.node(providerID: workspaceProviderID)
            let beforeStatus = beforeRevocation.workspaces.first { $0.id == workspaceID }?.status
            trace.record("workspace.owner-status.before-revocation.returned", [
                "effectiveStatus": beforeStatus?.rawValue ?? "missing",
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

            trace.record("workspace.owner-revocation.request")
            try workspaceNode.revoke()
            trace.record("workspace.owner-revocation.written")
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
            trace.record("workspace.owner-status.after-revocation.request", ["providerID": workspaceProviderID])
            let afterRevocation = try await diagnostics.node(providerID: workspaceProviderID)
            let afterStatus = afterRevocation.workspaces.first { $0.id == workspaceID }?.status
            trace.record("workspace.owner-status.after-revocation.returned", [
                "effectiveStatus": afterStatus?.rawValue ?? "missing",
            ])
            try #require(afterStatus == .unavailable)

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
                trace.record("third-peer.forged-invocation.rejected", ["reasonCode": error.reasonCode])
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
        let permissionResponder = Task {
            for await update in updates {
                trace.record("\(stagePrefix).update.received", [
                    "clientTurnID": clientTurnID,
                    "sequence": String(update.sequence),
                    "kind": update.kind,
                    "terminal": String(update.terminal),
                    "hasPermissionState": String(update.permissionState != nil),
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
            }
            trace.record("\(stagePrefix).updates.finished")
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
        try await permissionResponder.value
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
        workspaceID: UUID? = nil,
        workspaceURI: String? = nil
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
            let fixtureEnvironment = [
                "GNOSTIC_ACP_FIXTURE_STATE": fixtureState.path,
                "GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE": fixturePID.path,
            ]
            manifest.ascendants[0].backend.settings["command"] = .string("node")
            manifest.ascendants[0].backend.settings["args"] = .string(try jsonString([agentFixture]))
            manifest.ascendants[0].backend.settings["env"] = .string(try jsonString(fixtureEnvironment))
            if let requestedTimelineID, let workspaceID, let workspaceURI {
                manifest.timelines[0].id = requestedTimelineID
                manifest.ascendants[0].defaultTimelineID = requestedTimelineID
                manifest.timelines[0].attachments = [.network(workspaceID, uri: workspaceURI)]
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
