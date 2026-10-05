// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Proof that the Atlas module is installed by `gnostic serve`, not only by the
/// composition tests (GNO-PLAT-021, #449).
///
/// The manifest selects `extensions: ["atlas"]`, so startup must materialize
/// the Positronic backend with the descriptor's contribution and install the
/// descriptor's terminal Turn observer. A broken descriptor fails startup
/// before the advertised-objects fence, which makes this test the end-to-end
/// serve proof.
@Suite("Atlas serve manifest", .serialized)
struct AtlasServeManifestTests {
    @Test("gnostic serve starts and stops with an atlas-selecting manifest", .timeLimit(.minutes(1)))
    @MainActor
    func serveStartsWithAtlasManifest() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_SERVE_BINARY"])
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-atlas-serve-\(UUID().uuidString)")
        let store = CLIConfigurationStore(baseDirectory: configDirectory, environment: [:])
        try store.initializeManifest()
        try store.mutateManifest { manifest in
            manifest.ascendants[0].backend.settings["extensions"] = .array([.string("atlas")])
        }
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        let namespace = "serve-atlas-\(UUID().uuidString.lowercased())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "serve", "--config", store.path().path,
            "--host", "127.0.0.1", "--port", "1883", "--namespace", namespace,
        ]
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-atlas-serve-\(UUID().uuidString).log")
        #expect(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        var sawOnline = false
        for _ in 0..<150 {
            try log.synchronize()
            let output = try String(contentsOf: logURL, encoding: .utf8)
            // The advertised-objects trace line is the startup fence the serve
            // suite uses; the stdout "online" banner is block-buffered.
            if output.contains("advertised objects") {
                sawOnline = true
                break
            }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try log.synchronize()
        let startupLog = try String(contentsOf: logURL, encoding: .utf8)
        #expect(sawOnline, Comment(rawValue: startupLog))
        #expect(process.isRunning, Comment(rawValue: startupLog))
        process.terminate()

        for _ in 0..<40 where process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let exited = !process.isRunning
        if !exited { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()

        try log.synchronize()
        let standardError = try String(contentsOf: logURL, encoding: .utf8)
        #expect(exited, "gnostic serve ignored SIGTERM")
        #expect(process.terminationReason == .exit, Comment(rawValue: standardError))
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
    }
}
