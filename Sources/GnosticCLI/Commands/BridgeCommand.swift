// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// `gnostic bridge` — a long-lived JSON-RPC stdio frontend for pi and similar
/// process hosts. Exactly one Axoloty connection is shared by the session.
struct BridgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge",
        abstract: "Run the single-connection JSON-RPC stdio bridge."
    )

    @Option(name: .long, help: "MQTT broker host (overrides config).")
    var host: String?

    @Option(name: .long, help: "MQTT broker port (overrides config).")
    var port: Int?

    @Option(name: .long, help: "MQTT namespace (overrides config).")
    var namespace: String?

    @MainActor
    func run() async throws {
        FileHandle.standardError.write(Data("warning: `gnostic bridge` is deprecated; use `gnostic acp` instead.\n".utf8))
        let store = CLIConfigurationStore()
        let stored = try store.load()
        let client = try GnosticRemoteClient(
            host: host ?? stored.mqttHost,
            port: port ?? stored.mqttPort,
            namespace: namespace ?? stored.mqttNamespace
        )
        defer { client.stop() }
        try await BridgeServer(client: client).run()
    }
}
