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
            signalDelay: .milliseconds(100),
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

        try await Task.sleep(for: signalDelay)
        #expect(process.isRunning)
        if requireOnlineBeforeSignal {
            try log.synchronize()
            let startupLog = try String(contentsOf: logURL, encoding: .utf8)
            #expect(startupLog.contains("objectCount=0"), Comment(rawValue: startupLog))
        }
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
}

private enum TestSignal: String { case interrupt = "SIGINT", terminate = "SIGTERM" }
