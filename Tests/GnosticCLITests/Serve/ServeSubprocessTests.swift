// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Serve subprocess", .serialized)
struct ServeSubprocessTests {
    @Test("effective launch plan preserves manifest node settings without CLI overrides")
    func effectiveLaunchPlanPreservesManifestNodeSettings() throws {
        let manifest = NodeManifest.makeDefault(
            broker: .init(host: "manifest.example", port: 1_883, namespace: "manifest")
        )
        var configuredManifest = manifest
        configuredManifest.node.approvalMode = "deny"
        configuredManifest.node.logLevel = "warning"
        let expectedTimelineIDs = configuredManifest.timelines.map(\.id)

        var manifestLoads = 0
        let plan = try ServeLaunchPlan.load(
            manifest: {
                manifestLoads += 1
                return configuredManifest
            },
            configuration: { _ in
                // Simulate a concurrent manifest write after the load has
                // released its file lock. The plan must retain the snapshot.
                configuredManifest.node.approvalMode = "auto"
                configuredManifest.timelines = []
                return .init(
                    mqttHost: "environment.example",
                    mqttPort: 1_884,
                    mqttNamespace: "environment",
                    mqttUsername: "environment-user",
                    mqttPassword: "environment-secret",
                    llmProvider: nil,
                    llmEndpoint: nil,
                    llmModel: nil,
                    llmUtilityModel: nil,
                    llmFastModel: nil,
                    llmAPIKey: nil
                )
            },
            overrides: .init(host: nil, port: nil, namespace: nil, approvalMode: nil, logLevel: nil)
        )

        #expect(manifestLoads == 1)
        #expect(plan.broker.host == "environment.example")
        #expect(plan.broker.port == 1_884)
        #expect(plan.broker.namespace == "environment")
        #expect(plan.broker.username == "environment-user")
        #expect(plan.broker.password == "environment-secret")
        #expect(plan.node.approvalMode == "deny")
        #expect(plan.node.logLevel == "warning")
        #expect(plan.timelines.map(\.id) == expectedTimelineIDs)
    }

    @Test("effective launch plan validates explicit CLI overrides after precedence")
    func effectiveLaunchPlanValidatesExplicitOverrides() throws {
        let manifest = NodeManifest.makeDefault(
            broker: .init(host: "manifest.example", port: 1_883, namespace: "manifest")
        )

        let plan = try ServeLaunchPlan.compile(
            manifest: manifest,
            configuration: .defaults,
            overrides: .init(host: "cli.example", port: 1_885, namespace: "cli", approvalMode: "deny", logLevel: "error")
        )
        #expect(plan.broker.host == "cli.example")
        #expect(plan.broker.port == 1_885)
        #expect(plan.broker.namespace == "cli")
        #expect(plan.node.approvalMode == "deny")
        #expect(plan.node.logLevel == "error")

        #expect(throws: NodeManifestError.invalidNodeSettings) {
            try ServeLaunchPlan.compile(
                manifest: manifest,
                configuration: .defaults,
                overrides: .init(host: nil, port: nil, namespace: nil, approvalMode: "invalid", logLevel: nil)
            )
        }
    }

    @Test("SIGTERM gracefully stops gnostic serve", .timeLimit(.minutes(1)))
    @MainActor
    func sigtermStopsServe() async throws {
        try await assertGracefulStop(using: .terminate)
    }

    @Test("SIGINT gracefully stops gnostic serve", .timeLimit(.minutes(1)))
    @MainActor
    func sigintStopsServe() async throws {
        try await assertGracefulStop(using: .interrupt)
    }

    @Test("SIGINT gracefully stops gnostic serve during startup", .timeLimit(.minutes(1)))
    @MainActor
    func sigintStopsServeDuringStartup() async throws {
        try await assertGracefulStop(
            using: .interrupt,
            port: 1,
            // Give the launched Swift process enough time to enter `run()` and
            // install its signal sources; it is still blocked in broker startup.
            signalDelay: .milliseconds(500),
            requireOnlineBeforeSignal: false
        )
    }

    @MainActor
    private func assertGracefulStop(
        using signal: TestSignal,
        port: Int = 1883,
        signalDelay: Duration = .seconds(1),
        requireOnlineBeforeSignal: Bool = true
    ) async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_SERVE_BINARY"])
        let namespace = "serve-signal-\(UUID().uuidString.lowercased())"
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-serve-config-\(UUID().uuidString)")
        let configStore = CLIConfigurationStore(baseDirectory: configDirectory, environment: [:])
        try configStore.setValue("127.0.0.1", for: .mqttHost)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "serve", "--config", configStore.path().path,
            "--host", "127.0.0.1", "--port", String(port), "--namespace", namespace,
        ]
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-serve-\(UUID().uuidString).log")
        #expect(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: configDirectory)
        }

        if requireOnlineBeforeSignal {
            try await waitForOnline(log: log, logURL: logURL, process: process)
        } else {
            try await Task.sleep(for: signalDelay)
        }
        #expect(process.isRunning)
        switch signal {
        case .interrupt: process.interrupt()
        case .terminate: process.terminate()
        }

        for _ in 0..<40 where process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let exited = !process.isRunning
        if !exited { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()

        try log.synchronize()
        let standardError = try String(contentsOf: logURL, encoding: .utf8)
        #expect(exited, "gnostic serve ignored \(signal)")
        #expect(process.terminationReason == .exit, Comment(rawValue: standardError))
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
    }

    /// Polls the serve log until it advertises its object graph. A fixed delay
    /// is too short when the suite runs in parallel: subprocess launch and the
    /// broker connection can take well over a second under load, so signaling
    /// early could hit the default handler before the monitor is installed.
    @MainActor
    private func waitForOnline(log: FileHandle, logURL: URL, process: Process) async throws {
        var sawOnline = false
        for _ in 0..<150 {
            try log.synchronize()
            if try String(contentsOf: logURL, encoding: .utf8).contains("objectCount=0") {
                sawOnline = true
                break
            }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try log.synchronize()
        let startupLog = try String(contentsOf: logURL, encoding: .utf8)
        #expect(sawOnline, Comment(rawValue: startupLog))
    }
}

private enum TestSignal: String { case interrupt = "SIGINT", terminate = "SIGTERM" }
