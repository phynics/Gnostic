// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import Logging
import PKShared
import PositronicKit

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

    @Option(name: .long, help: "Approval mode for workspace attach/detach: auto or deny.")
    var approveMode: String = "auto"

    @Option(name: .long, help: "Log level: debug, info, warning, or error (default info).")
    var logLevel: String = "info"

    /// Runs the serve process until interrupted.
    @MainActor
    func run() async throws {
        let terminationMonitor = ProcessTerminationMonitor()
        defer { terminationMonitor.cancel() }

        // Configure SwiftLog so serve emits timestamped, parseable records.
        let level = Logger.Level(rawValue: logLevel.lowercased()) ?? .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }

        let store = CLIConfigurationStore(configPath: configPath.map { URL(fileURLWithPath: $0) })
        do {
            _ = try store.loadManifest().compileLaunchPlan()
        } catch let error as CLIConfigurationError {
            if case .missingFile = error {
                throw ValidationError("No configuration manifest exists; run `gnostic config init` before `gnostic serve`.")
            }
            throw error
        }
        let stored = try store.load()
        let host = self.host ?? stored.mqttHost
        let port = self.port ?? stored.mqttPort
        let namespace = self.namespace ?? stored.mqttNamespace
        var plan = try store.loadManifest().compileLaunchPlan()
        var broker = plan.broker
        broker.host = host
        broker.port = port
        broker.namespace = namespace
        var node = plan.node
        node.approvalMode = approveMode.lowercased() == "deny" ? "deny" : "auto"
        node.logLevel = logLevel.lowercased()
        plan = NodeLaunchPlan(node: node, broker: broker, llmProfiles: plan.llmProfiles, ascendants: plan.ascendants, timelines: plan.timelines, workspaces: plan.workspaces)

        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.register(kind: "positronic") { _, profile in
            if let profile { return ConfiguredLLMService.make(from: profile) }
            return UnconfiguredLLMService()
        }
        let runtime = try await NodeRuntime(plan: plan, adapters: adapters)
        do {
            guard try await start(runtime: runtime, until: terminationMonitor) else { return }
            let timelineID = runtime.snapshot().timelineIDs.first
            ServeTrace.advertised(
                logger: ServeLogging.makeLogger(),
                objects: runtime.snapshot().ascendantIDs.count + runtime.snapshot().timelineIDs.count,
                timelineID: timelineID ?? runtime.plan.nodeID
            )
            let timelineText = timelineID?.uuidString.lowercased() ?? "none"
            print("gnostic serve online at \(host):\(port) namespace \(namespace) timeline \(timelineText)")
            print("Press Ctrl-C to shut down.")

            await terminationMonitor.wait()
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
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
