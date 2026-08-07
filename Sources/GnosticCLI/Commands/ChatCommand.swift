// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore

/// `gnostic chat` — a pure Axoloty client for `gnostic serve`.
///
/// Contains no PositronicKit runtime and no local-chat fallback; every turn and
/// workspace operation is a unary Call/Return over the Axoloty stack.
struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Chat with a serve agent over the Axoloty stack."
    )

    @Option(name: .long, help: "MQTT broker host (overrides config).")
    var host: String?

    @Option(name: .long, help: "MQTT broker port (overrides config).")
    var port: Int?

    @Option(name: .long, help: "MQTT namespace (overrides config).")
    var namespace: String?

    @MainActor
    func run() async throws {
        let store = CLIConfigurationStore()
        let stored = try store.load()
        let host = self.host ?? stored.mqttHost
        let port = self.port ?? stored.mqttPort
        let namespace = self.namespace ?? stored.mqttNamespace

        let client = try RemoteChatClient(host: host, port: port, namespace: namespace)
        defer { client.stop() }
        try await client.connect()

        // Discover the served agent's canonical timeline, then list the serve's
        // timelines and select one as active. With multi-timeline ownership, the
        // enumeration source is timeline.list; default to the first timeline (or
        // the advertised default when none is listed yet).
        let defaultID = try await client.discoverServedTimeline()
        let timelines = try await client.listTimelines()
        let timelineID = timelines.first?.timelineID ?? defaultID

        let session = RemoteChatSession(client: client, timelineID: timelineID)
        let repl = ChatREPL(
            session: session,
            timelineID: timelineID,
            approval: StdinApprovalPolicy(),
            readLine: { readLine(strippingNewline: true) }
        )
        print("gnostic chat — timeline \(timelineID.uuidString.lowercased())")
        print("Type a message, /quit to exit, or /timeline, /timelines, /new, /use <id>, /rename <title>, /workspaces, /attach <id>, /detach <id>.")
        await repl.run()
    }
}