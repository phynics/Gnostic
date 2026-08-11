// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore

/// `gnostic acp` — an ACP v1 agent projection of one Gnostic Ascendant.
struct ACPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acp",
        abstract: "Expose a Gnostic Ascendant through ACP over stdio."
    )

    @Argument(help: "Optional operation (`profiles`).")
    var operation: String?

    @Flag(name: .long, help: "Emit a versioned profile source as JSON.")
    var json = false

    @Option(name: .long, help: "MQTT broker host (overrides config).")
    var host: String?

    @Option(name: .long, help: "MQTT broker port (overrides config).")
    var port: Int?

    @Option(name: .long, help: "MQTT namespace (overrides config).")
    var namespace: String?

    @Option(name: .long, help: "Ascendant UUID to pin for this ACP process.")
    var ascendant: String?

    @MainActor
    func run() async throws {
        let store = CLIConfigurationStore()
        let stored = try store.load()
        if let operation {
            guard operation == "profiles" else {
                throw ValidationError("unknown acp operation: \(operation)")
            }
            guard json else { throw ValidationError("profiles requires --json") }
            try await printProfiles(using: stored)
            return
        }
        guard !json else { throw ValidationError("--json requires the profiles operation") }
        let ascendantID = try ascendant.map { value in
            guard let id = UUID(uuidString: value) else {
                throw ValidationError("--ascendant must be a UUID")
            }
            return id
        }
        let client = try GnosticRemoteClient(
            host: host ?? stored.mqttHost,
            port: port ?? stored.mqttPort,
            namespace: namespace ?? stored.mqttNamespace,
            // ACP prompts may wait on an interactive permission decision.
            // Keep discovery calls bounded while allowing the authoritative
            // unary turn enough time to survive that interaction.
            promptTimeout: .seconds(300)
        )
        try await ACPServer(
            client: client,
            ascendantID: ascendantID,
            registry: ACPSessionRegistry()
        ).run()
    }

    @MainActor
    private func printProfiles(using stored: CLIConfiguration) async throws {
        let client = try GnosticRemoteClient(
            host: host ?? stored.mqttHost,
            port: port ?? stored.mqttPort,
            namespace: namespace ?? stored.mqttNamespace
        )
        defer { client.stop() }
        try await client.connect()
        let entries = await client.listNetworkObjects().filter { $0.objectType == GnosticObjectType.agent }
        let profiles = entries.map { entry in
            ACPProfile(
                id: "gnostic-\(entry.objectID.uuidString.lowercased())",
                name: entry.name,
                command: "gnostic",
                args: [
                    "acp",
                    "--host", host ?? stored.mqttHost,
                    "--port", String(port ?? stored.mqttPort),
                    "--namespace", namespace ?? stored.mqttNamespace,
                    "--ascendant", entry.objectID.uuidString.lowercased(),
                ],
                env: [:]
            )
        }.sorted { $0.id < $1.id }
        // Dynamic profile sources may emit only their executable profiles;
        // profile selection remains owned by pi-acp-client's trusted config.
        let bundle = ACPProfileBundle(version: 1, defaultProfile: nil, profiles: profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(bundle) + Data([0x0A]))
    }
}
