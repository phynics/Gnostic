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

    @MainActor
    private func assertGracefulStop(using signal: TestSignal) async throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_SERVE_BINARY"] else { return }
        let namespace = "serve-signal-\(UUID().uuidString.lowercased())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "serve", "--host", "127.0.0.1", "--port", "1883", "--namespace", namespace,
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        try await Task.sleep(for: .seconds(1))
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

        let standardError = String(
            decoding: error.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(exited, "gnostic serve ignored \(signal)")
        #expect(process.terminationReason == .exit, Comment(rawValue: standardError))
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
    }
}

private enum TestSignal: String { case interrupt = "SIGINT", terminate = "SIGTERM" }
