// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore

/// The `gnostic-runner` executable.
@main
struct GnosticRunner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic-runner",
        abstract: "Advertise Gnostic objects and drive the Ascendant-network PoC."
    )

    @Option(help: "MQTT broker host (defaults to GNOSTIC_HOST or 127.0.0.1).")
    var host: String?

    @Option(help: "MQTT broker port (defaults to GNOSTIC_PORT or 1883).")
    var port: Int?

    @Option(help: "MQTT namespace (defaults to GNOSTIC_NAMESPACE or gnostic).")
    var namespace: String?

    @MainActor
    func run() async throws {
        let configuration = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: host, port: port, namespace: namespace),
            environment: ProcessInfo.processInfo.environment
        )
        let runtime = try RunnerRuntime(configuration: configuration)
        defer { runtime.shutdown() }
        try await runtime.start()
        print("gnostic-runner online at \(configuration.host):\(configuration.port) namespace \(configuration.namespace)")
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            _ = continuation
        }
    }
}

/// Structured parsing failures for the runner's command-line configuration.
