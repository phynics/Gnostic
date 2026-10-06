// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import GnosticHost
import Logging

/// `gnostic serve` — a persistent process that advertises Gnostic objects and
/// hosts the network operations remote clients use.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Advertise Gnostic objects and serve network operations."
    )

    @Option(name: .long, help: "MQTT broker host (overrides config).")
    var host: String?

    @Option(name: .customLong("config"), help: "Path to the node manifest.")
    var configPath: String?

    @Option(name: .long, help: "MQTT broker port (overrides config).")
    var port: Int?

    @Option(name: .long, help: "MQTT namespace (overrides config).")
    var namespace: String?

    @Option(name: .long, help: "Approval mode for workspace attach/detach (overrides config): auto or deny.")
    var approveMode: String?

    @Option(name: .long, help: "Log level (overrides config): trace, debug, info, warning, or error.")
    var logLevel: String?

    @Option(name: .customLong("metrics-file"), help: "Write a bounded runtime metrics snapshot (JSON) to this file.")
    var metricsFile: String?

    @Option(name: .customLong("metrics-interval"), help: "Seconds between metrics snapshots (default 5).")
    var metricsIntervalSeconds: Double = 5

    @Option(name: .customLong("turn-log"), help: "Path to the durable Turn event log (overrides GNOSTIC_STATE_HOME).")
    var turnLogPath: String?

    /// Resolves the durable state directory used for derived state. An explicit
    /// `--turn-log` names a file; its parent directory is the state home.
    /// Otherwise `GNOSTIC_STATE_HOME` opts in, and an unset state directory
    /// keeps the default in-memory behavior.
    private func resolveStateHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let turnLogPath, !turnLogPath.isEmpty {
            return URL(fileURLWithPath: turnLogPath).deletingLastPathComponent()
        }
        guard let stateHome = environment["GNOSTIC_STATE_HOME"], !stateHome.isEmpty else { return nil }
        return URL(fileURLWithPath: stateHome, isDirectory: true)
    }

    /// Resolves the durable Turn event log location. An explicit `--turn-log`
    /// is used verbatim; otherwise the log is derived under the state home.
    func resolveTurnLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let turnLogPath, !turnLogPath.isEmpty {
            return URL(fileURLWithPath: turnLogPath)
        }
        return resolveStateHome(environment: environment)?.appendingPathComponent("turn-events-v1.jsonl")
    }

    /// Resolves the per-Ascendant Timeline transcript directory under the
    /// state home. Timeline durability is opt-in for the same reason the Turn
    /// log is: an unset state directory keeps the process-scoped default.
    func resolveTimelineStoreDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        resolveStateHome(environment: environment)?.appendingPathComponent("timelines", isDirectory: true)
    }

    /// Runs the serve process until interrupted.
    @MainActor
    func run() async throws {
        let terminationMonitor = ProcessTerminationMonitor()
        defer { terminationMonitor.cancel() }

        let store = CLIConfigurationStore(configPath: configPath.map { URL(fileURLWithPath: $0) })
        do {
            let plan = try ServeLaunchPlan.load(
                manifest: store.loadManifest,
                configuration: store.effectiveConfiguration(for:),
                overrides: .init(host: host, port: port, namespace: namespace, approvalMode: approveMode, logLevel: logLevel)
            )

            // Configure SwiftLog from the validated, effective launch plan.
            let level = Logger.Level(rawValue: plan.node.logLevel) ?? .info
            LoggingSystem.bootstrap { label in
                var handler = StreamLogHandler.standardOutput(label: label)
                handler.logLevel = level
                return handler
            }

            let adapters = BackendComposition.default.makeAdapters(for: plan.ascendants)
            let runtime = try await NodeRuntime(
                plan: plan,
                adapters: adapters,
                turnLogURL: resolveTurnLogURL(),
                timelineStoreDirectory: resolveTimelineStoreDirectory()
            )
            do {
                guard try await start(runtime: runtime, until: terminationMonitor) else { return }
                let snapshot = await runtime.snapshot()
                let timelineID = snapshot.timelineIDs.first
                ServeTrace.advertised(
                    logger: ServeLogging.makeLogger(),
                    objects: snapshot.ascendantIDs.count + snapshot.timelineIDs.count,
                    timelineID: timelineID ?? runtime.plan.nodeID
                )
                let timelineText = timelineID?.uuidString.lowercased() ?? "none"
                print("gnostic serve online at \(plan.broker.host):\(plan.broker.port) namespace \(plan.broker.namespace) timeline \(timelineText)")
                print("Press Ctrl-C to shut down.")

                // Soak resource tracking (GNO-PLAT-062, #454). The writer only
                // runs when a path is given; it never changes serve behavior.
                let metricsTask = metricsFile.map { path in
                    Task { @MainActor in
                        let url = URL(fileURLWithPath: path)
                        let interval = Duration.seconds(max(1, metricsIntervalSeconds))
                        while !Task.isCancelled {
                            if let data = try? JSONEncoder().encode(await runtime.metrics()) {
                                try? data.write(to: url, options: .atomic)
                            }
                            try? await Task.sleep(for: interval)
                        }
                    }
                }
                defer { metricsTask?.cancel() }

                await terminationMonitor.wait()
            } catch {
                await runtime.shutdown()
                throw error
            }
            await runtime.shutdown()
        } catch let error as CLIConfigurationError {
            if case .missingFile = error {
                throw ValidationError("No configuration manifest exists; run `gnostic config init` before `gnostic serve`.")
            }
            throw error
        }
    }
}

struct ServeLaunchOverrides: Sendable {
    let host: String?
    let port: Int?
    let namespace: String?
    let approvalMode: String?
    let logLevel: String?
}

/// Compiles the immutable startup input from exactly one manifest snapshot.
enum ServeLaunchPlan {
    static func load(
        manifest: () throws -> NodeManifest,
        configuration: (NodeManifest) throws -> CLIConfiguration,
        overrides: ServeLaunchOverrides
    ) throws -> NodeLaunchPlan {
        let manifest = try manifest()
        return try compile(manifest: manifest, configuration: configuration(manifest), overrides: overrides)
    }

    static func compile(
        manifest: NodeManifest,
        configuration: CLIConfiguration,
        overrides: ServeLaunchOverrides
    ) throws -> NodeLaunchPlan {
        var effective = manifest
        effective.broker.host = overrides.host ?? configuration.mqttHost
        effective.broker.port = overrides.port ?? configuration.mqttPort
        effective.broker.namespace = overrides.namespace ?? configuration.mqttNamespace
        effective.broker.username = configuration.mqttUsername
        effective.broker.password = configuration.mqttPassword
        effective.broker = effective.broker.normalized()
        if let approvalMode = overrides.approvalMode {
            effective.node.approvalMode = approvalMode.lowercased()
        }
        if let logLevel = overrides.logLevel {
            effective.node.logLevel = logLevel.lowercased()
        }
        return try effective.compileLaunchPlan()
    }
}

private enum ServeStartupOutcome: Sendable {
    case started
    case terminated
}

@MainActor
private func start(runtime: NodeRuntime, until terminationMonitor: ProcessTerminationMonitor) async throws -> Bool {
    try await withThrowingTaskGroup(of: ServeStartupOutcome.self) { group in
        group.addTask {
            try await runtime.start()
            return .started
        }
        group.addTask {
            await terminationMonitor.wait()
            return .terminated
        }

        let outcome = try await group.next() ?? .terminated
        group.cancelAll()

        if outcome == .terminated {
            await runtime.shutdown()
            try? await group.waitForAll()
            return false
        }

        try await group.waitForAll()
        return true
    }
}
