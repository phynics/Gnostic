// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore

/// `gnostic acp` — an ACP v1 Ascendant projection of one Gnostic Ascendant.
struct ACPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acp",
        abstract: "Expose a Gnostic Ascendant through ACP over stdio."
    )

    @Argument(help: "Optional operation (`profiles`).")
    var operation: String?

    @Flag(name: .long, help: "Emit a versioned profile source as JSON.")
    var json = false

    @Flag(name: .long, help: "Refresh the short-lived cached profile discovery.")
    var refresh = false

    @Option(name: .long, help: "MQTT broker host (overrides config).")
    var host: String?

    @Option(name: .long, help: "MQTT broker port (overrides config).")
    var port: Int?

    @Option(name: .long, help: "MQTT namespace (overrides config).")
    var namespace: String?

    @Option(name: .long, help: "Ascendant UUID to pin for this ACP process.")
    var ascendant: String?

    @Option(name: .long, help: "Provider identity to pin for this ACP process. Prefer --node.")
    var provider: String?

    @Option(name: .long, help: "Node UUID to pin for this ACP process.")
    var node: String?

    @MainActor
    func run() async throws {
        let store = CLIConfigurationStore()
        let stored = try store.load()
        if let operation {
            guard operation == "profiles" else {
                throw ValidationError("unknown acp operation: \(operation)")
            }
            guard json else { throw ValidationError("profiles requires --json") }
            try await printProfiles(using: stored, refresh: refresh)
            return
        }
        guard !json else { throw ValidationError("--json requires the profiles operation") }
        let ascendantID = try ascendant.map { value in
            guard let id = UUID(uuidString: value) else {
                throw ValidationError("--ascendant must be a UUID")
            }
            return id
        }
        let nodeID = try node.map { value in
            guard let id = UUID(uuidString: value) else {
                throw ValidationError("--node must be a UUID")
            }
            return id
        }
        let client = try RemoteTurnClient(
            host: host ?? stored.mqttHost,
            port: port ?? stored.mqttPort,
            namespace: namespace ?? stored.mqttNamespace,
            username: stored.mqttUsername,
            password: stored.mqttPassword,
            // ACP prompts may wait on an interactive permission decision.
            // Keep discovery calls bounded while allowing the authoritative
            // unary turn enough time to survive that interaction.
            promptTimeout: .seconds(300)
        )
        try await ACPServer(
            client: client,
            ascendantID: ascendantID,
            providerID: provider,
            nodeID: nodeID,
            registry: ACPSessionRegistry()
        ).run()
    }

    @MainActor
    private func printProfiles(using stored: CLIConfiguration, refresh: Bool) async throws {
        let brokerKey = ACPProfileCacheKey(
            host: host ?? stored.mqttHost,
            port: port ?? stored.mqttPort,
            namespace: namespace ?? stored.mqttNamespace
        )
        let cache = ACPProfileCache()
        if !refresh, let cached = cache.load(for: brokerKey), cached.isRestartStable {
            try writeProfiles(cached)
            return
        }
        let client = try RemoteTurnClient(
            host: brokerKey.host,
            port: brokerKey.port,
            namespace: brokerKey.namespace,
            username: stored.mqttUsername,
            password: stored.mqttPassword
        )
        // Every exit path stops the client: a throwing connect, cache
        // store, or profile write must not leak the manager and its
        // subscription.
        do {
            try await client.connect()
            let entries = await client.listNetworkObjects().filter { $0.objectType == GnosticObjectType.ascendant }
            let profiles = Self.profiles(
                from: entries,
                host: host ?? stored.mqttHost,
                port: port ?? stored.mqttPort,
                namespace: namespace ?? stored.mqttNamespace
            )
            // Dynamic profile sources may emit only their executable profiles;
            // profile selection remains owned by pi-acp-client's trusted config.
            let bundle = ACPProfileBundle(version: 1, defaultProfile: nil, profiles: profiles)
            try cache.store(bundle, for: brokerKey)
            try writeProfiles(bundle)
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }

    /// Builds one profile per served Ascendant, per node.
    ///
    /// A profile carries a disambiguating selector only when more than one node
    /// advertises the same Ascendant identifier, and that selector is the node
    /// identity. The provider identity changes with every serve process, so
    /// pinning it would invalidate the profile at the next restart. It remains
    /// the fallback selector for a serve that advertises no node identity.
    static func profiles(
        from entries: [NetworkCatalogEntry],
        host: String,
        port: Int,
        namespace: String
    ) -> [ACPProfile] {
        var profiles: [ACPProfile] = []
        for (ascendantID, advertised) in Dictionary(grouping: entries, by: \.objectID) {
            var byNode: [String: NetworkCatalogEntry] = [:]
            for entry in advertised.sorted(by: { $0.providerID < $1.providerID }) {
                let key = RemoteTurnClient.nodeID(of: entry)?.uuidString.lowercased()
                    ?? "provider:\(entry.providerID.lowercased())"
                if byNode[key] == nil { byNode[key] = entry }
            }
            let needsSelector = byNode.count > 1
            for entry in byNode.values {
                var identifier = "gnostic-\(ascendantID.uuidString.lowercased())"
                var args = [
                    "acp",
                    "--host", host,
                    "--port", String(port),
                    "--namespace", namespace,
                    "--ascendant", ascendantID.uuidString.lowercased(),
                ]
                if needsSelector {
                    if let nodeID = RemoteTurnClient.nodeID(of: entry)?.uuidString.lowercased() {
                        identifier += "-\(nodeID)"
                        args += ["--node", nodeID]
                    } else {
                        identifier += "-\(entry.providerID.lowercased())"
                        args += ["--provider", entry.providerID.lowercased()]
                    }
                }
                profiles.append(ACPProfile(
                    id: identifier,
                    name: entry.name,
                    command: "gnostic",
                    args: args,
                    env: [:]
                ))
            }
        }
        return profiles.sorted { $0.id < $1.id }
    }

    private func writeProfiles(_ bundle: ACPProfileBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(bundle) + Data([0x0A]))
    }
}
