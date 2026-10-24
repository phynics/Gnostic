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

@Suite("Two Node MQTT process integration", .serialized, .timeLimit(.minutes(1)))
struct TwoNodeMQTTIntegrationTests {
    @Test("separate serve processes route Turns and observations to each Timeline owner")
    @MainActor
    func routesTurnsAcrossTwoLiveNodes() async throws {
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
        defer { stop(first) }
        let second = try await launchNode(
            name: "second",
            namespace: namespace,
            serveBinary: serveBinary,
            agentFixture: agentFixture,
            scratch: scratch
        )
        defer { stop(second) }

        let session = try GnosticConsumerSession(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(3)
        )
        try await session.start()
        defer { Task { @MainActor in await session.stop() } }
        let client = try session.turnClient(timeout: .seconds(3), promptTimeout: .seconds(8))

        for node in [first, second] {
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

            let result = try await client.run(
                message: message,
                timelineID: node.timelineID,
                clientTurnID: clientTurnID
            )
            let received = await observation.value

            #expect(result.text == "fixture reply: \(message)")
            #expect(received.map(\.text).compactMap { $0 }.joined() == "fixture reply: \(message)")
            #expect(received.last?.kind == AscendantTurnUpdateKind.completion.rawValue)
            #expect(received.last?.terminal == true)
        }
    }

    @MainActor
    private func launchNode(
        name: String,
        namespace: String,
        serveBinary: String,
        agentFixture: String,
        scratch: URL
    ) async throws -> NodeProcess {
        let configDirectory = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let store = CLIConfigurationStore(baseDirectory: configDirectory, environment: [:])
        _ = try store.initializeManifest()
        let manifest = try store.loadManifest()
        let timelineID = try #require(manifest.timelines.first?.id)
        let fixtureState = configDirectory.appendingPathComponent("fixture-sessions.json")
        try store.mutateManifest { manifest in
            let fixtureEnvironment = ["GNOSTIC_ACP_FIXTURE_STATE": fixtureState.path]
            manifest.ascendants[0].backend.settings["command"] = .string("node")
            manifest.ascendants[0].backend.settings["args"] = .string(try jsonString([agentFixture]))
            manifest.ascendants[0].backend.settings["env"] = .string(try jsonString(fixtureEnvironment))
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
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()

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
        return NodeProcess(name: name, timelineID: timelineID, process: process, log: log)
    }

    @MainActor
    private func stop(_ node: NodeProcess) {
        if node.process.isRunning {
            node.process.terminate()
            for _ in 0..<50 where node.process.isRunning { usleep(100_000) }
            if node.process.isRunning {
                _ = kill(node.process.processIdentifier, SIGKILL)
            }
            node.process.waitUntilExit()
        }
        try? node.log.close()
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try #require(String(data: data, encoding: .utf8))
    }
}

private struct NodeProcess {
    let name: String
    let timelineID: UUID
    let process: Process
    let log: FileHandle
}

private enum TwoNodeIntegrationError: Error {
    case nodeFailedToStart(String)
}
