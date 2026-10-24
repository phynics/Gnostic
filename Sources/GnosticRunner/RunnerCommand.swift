// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Dispatch
import Foundation
import GnosticCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// The `gnostic-runner` executable.
@main
struct GnosticRunner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic-runner",
        abstract: "Advertise Gnostic objects and drive the Ascendant-network PoC."
    )

    @Option(name: .customLong("config"), help: "Path to the node manifest (overrides GNOSTIC_CONFIG).")
    var configPath: String?

    @Option(name: .customLong("state-home"), help: "Directory for durable Timeline journals (overrides GNOSTIC_STATE_HOME).")
    var stateHome: String?

    @Option(help: "MQTT broker host (defaults to GNOSTIC_HOST or 127.0.0.1).")
    var host: String?

    @Option(help: "MQTT broker port (defaults to GNOSTIC_PORT or 1883).")
    var port: Int?

    @Option(help: "MQTT namespace (defaults to GNOSTIC_NAMESPACE or gnostic).")
    var namespace: String?

    @MainActor
    func run() async throws {
        let termination = RunnerTerminationMonitor()
        let configuration = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: host, port: port, namespace: namespace, config: configPath, stateHome: stateHome),
            environment: ProcessInfo.processInfo.environment
        )
        let runtime = try await RunnerRuntime(configuration: configuration)
        do {
            try await runtime.start()
        } catch {
            await runtime.shutdown()
            throw error
        }
        print("gnostic-runner online at \(configuration.host):\(configuration.port) namespace \(configuration.namespace)")
        await termination.wait()
        await runtime.shutdown()
    }
}

/// Turns SIGINT and SIGTERM into an awaitable shutdown request.
@MainActor
private final class RunnerTerminationMonitor {
    private let sources: [DispatchSourceSignal]
    private let terminationSignals: AsyncStream<Void>

    init() {
        #if os(Linux)
        _ = Glibc.signal(SIGINT, SIG_IGN)
        _ = Glibc.signal(SIGTERM, SIG_IGN)
        #else
        _ = Darwin.signal(SIGINT, SIG_IGN)
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        #endif
        let pair = AsyncStream<Void>.makeStream()
        terminationSignals = pair.stream
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminate.setEventHandler {
            pair.continuation.yield(())
            pair.continuation.finish()
        }
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            pair.continuation.yield(())
            pair.continuation.finish()
        }
        sources = [terminate, interrupt]
        sources.forEach { $0.activate() }
    }

    func wait() async {
        for await _ in terminationSignals { break }
    }
}
