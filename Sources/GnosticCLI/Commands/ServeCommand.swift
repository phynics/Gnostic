// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
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

    @Option(name: .long, help: "MQTT broker port (overrides config).")
    var port: Int?

    @Option(name: .long, help: "MQTT namespace (overrides config).")
    var namespace: String?

    @Option(name: .long, help: "Approval mode for workspace attach/detach: auto or deny.")
    var approveMode: String = "auto"

    /// Runs the serve process until interrupted.
    @MainActor
    func run() async throws {
        let store = CLIConfigurationStore()
        let stored = try store.load()
        let host = self.host ?? stored.mqttHost
        let port = self.port ?? stored.mqttPort
        let namespace = self.namespace ?? stored.mqttNamespace
        let mode: ServeApproveMode = approveMode.lowercased() == "deny" ? .deny : .auto

        let runtime = try await ServeRuntime(host: host, port: port, namespace: namespace, approveMode: mode)
        do {
            try await runtime.start()

            // Advertise the served Agent, Timeline, and (for the fixture path) a
            // workspace with echo tools so chat can attach and invoke it.
            let agent = AgentInstance(
                name: "gnostic-serve",
                description: "Serves Gnostic network operations.",
                privateTimelineID: runtime.servedTimelineID
            )
            let timeline = try await runtime.currentTimeline()
            let workspace = WorkspaceReference(
                id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!,
                uri: WorkspaceURI(parsing: "workspace://serve")!,
                location: .runtime,
                tools: [.custom(.init(id: "workspace_echo", name: "Workspace echo", description: "Echoes fixture input."))],
                createdAt: Date()
            )
            await runtime.advertise(agent: agent, workspaces: [workspace])
            print("gnostic serve online at \(host):\(port) namespace \(namespace) timeline \(runtime.servedTimelineID.uuidString.lowercased())")
            print("Press Ctrl-C to shut down.")

            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                // Block until SIGINT (the process exits); shutdown is best-effort.
                _ = continuation
            }
        } catch {
            runtime.shutdown()
            throw error
        }
        runtime.shutdown()
    }
}