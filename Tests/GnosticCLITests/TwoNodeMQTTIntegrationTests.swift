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
        var completed = false
        defer {
            if completed {
                try? FileManager.default.removeItem(at: scratch)
            } else {
                print("Two-Node Workspace diagnostics retained at \(scratch.path)")
            }
        }

        let workspaceNode = try await launchWorkspaceNode(
            namespace: namespace,
            scratch: scratch,
            workspaceID: workspaceID,
            workspaceURI: workspaceURI
        )
        let owner: NodeProcess
        do {
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
        } catch {
            await workspaceNode.process.shutdown()
            throw error
        }
        do {
            try await runGatewayRevocationScenario(
                namespace: namespace,
                timelineID: timelineID,
                workspaceID: workspaceID,
                workspaceNode: workspaceNode
            )
        } catch {
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
        workspaceNode: WorkspaceNodeProcess
    ) async throws {
        let session = try GnosticConsumerSession(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(3)
        )
        do {
            try await session.start()
            try await session.discover(timeout: .seconds(3))
            let timeline = await session.networkObjects().first {
                $0.objectType == GnosticObjectType.timeline
                    && $0.objectID == timelineID
            }
            let providerID = try #require(timeline?.providerID)
            let client = try session.turnClient(timeout: .seconds(3), promptTimeout: .seconds(8))
            let workspaceClient = try session.workspaceClient(timeout: .seconds(5))
            try await workspaceClient.attach(
                workspaceID: workspaceID,
                to: timelineID,
                approved: true,
                providerID: providerID
            )

            let first = try await runTurnApprovingWorkspacePermission(
                client: client,
                timelineID: timelineID,
                clientTurnID: "peer-workspace-first",
                providerID: providerID,
                message: "[fixture:workspace-tool]"
            )
            #expect(first.text.contains("remote workspace result: fixture"))
            #expect(try workspaceNode.invocationCount() == 1)

            try workspaceNode.revoke()
            let rejected = try await runTurnApprovingWorkspacePermission(
                client: client,
                timelineID: timelineID,
                clientTurnID: "peer-workspace-revoked",
                providerID: providerID,
                message: "[fixture:workspace-tool-rejected]"
            )
            #expect(rejected.text.contains("workspace call rejected (-32003)"))
            #expect(try workspaceNode.invocationCount() == 1)
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @MainActor
    private func runTurnApprovingWorkspacePermission(
        client: GnosticTurnClient,
        timelineID: UUID,
        clientTurnID: String,
        providerID: String,
        message: String
    ) async throws -> AscendantTurnResult {
        let updates = try await client.updates(for: clientTurnID, timelineID: timelineID, providerID: providerID)
        let permissionResponder = Task {
            for await update in updates {
                guard let permission = update.permissionState, permission.status == "pending" else { continue }
                try client.respond(
                    to: AscendantPermissionResponse(
                        correlationID: permission.correlationID,
                        timelineID: timelineID,
                        clientTurnID: clientTurnID,
                        approved: true
                    ),
                    providerID: providerID
                )
            }
        }
        let result = try await client.run(
            message: message,
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            providerID: providerID
        )
        try await permissionResponder.value
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
        let timelineID = requestedTimelineID ?? (try #require(manifest.timelines.first?.id))
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
        workspaceURI: String
    ) async throws -> WorkspaceNodeProcess {
        let configDirectory = scratch.appendingPathComponent("workspace-owner", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let store = CLIConfigurationStore(baseDirectory: configDirectory, environment: [:])
        _ = try store.initializeManifest()
        try store.mutateManifest { manifest in
            manifest.ascendants = []
            manifest.timelines = []
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
        process.executableURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GNOSTIC_SERVE_BINARY"]))
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
            fixturePIDURL: nil
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
}
