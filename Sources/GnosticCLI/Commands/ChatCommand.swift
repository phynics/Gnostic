// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import PKShared
import PositronicKit

/// `gnostic chat` — an interactive REPL backed by PositronicKit.
struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Start an interactive chat with the configured LLM."
    )

    @Option(name: .long, help: "MQTT broker host (overrides config).")
    var host: String?

    @Option(name: .long, help: "MQTT broker port (overrides config).")
    var port: Int?

    @Option(name: .long, help: "MQTT namespace (overrides config).")
    var namespace: String?

    /// Runs the interactive REPL.
    @MainActor
    func run() async throws {
        let store = CLIConfigurationStore()
        let configuration = try store.load()

        // Build the model from the CLI configuration. When no provider is set,
        // fall back to an unconfigured model so the REPL can still start and
        // surface a structured error per turn.
        let model = configuration.llmConfiguration().map { configured in
            LLMService.configured(from: configured)
        } ?? UnconfiguredLLMService() as any LanguageModel

        let kit = PositronicKit(languageModel: model)
        let timeline = try await kit.timelineManager.createTimeline()
        let timelineID = timeline.id

        // Wire the Gnostic network management tools. The attachment service
        // uses a catalog populated by a subscription; for the first slice the
        // tools are registered with an empty in-memory store so they remain
        // honest about what they observed.
        let attachmentService = DiscoveredWorkspaceAttachmentService(
            catalog: NetworkCatalog(),
            workspaceStore: InMemoryWorkspacePersistence(),
            timelineManager: kit.timelineManager
        ) { _ in }
        let tools: [any Tool] = [
            ListNetworkObjectsTool(service: attachmentService),
            InspectNetworkObjectTool(service: attachmentService),
            AttachWorkspaceTool(service: attachmentService),
        ]

        let session = ChatSession(kit: kit, tools: tools, timelineID: timelineID)
        let repl = ChatREPL(
            session: session,
            timelineID: timelineID,
            approval: StdinApprovalPolicy(),
            readLine: { readLine(strippingNewline: true) }
        )
        print("gnostic chat — timeline \(timelineID.uuidString.lowercased())")
        print("Type a message, /quit to exit, /timeline to show the timeline ID.")
        await repl.run()
    }
}

