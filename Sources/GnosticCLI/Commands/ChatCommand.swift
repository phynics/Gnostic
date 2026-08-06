// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import PKAnthropicProvider
import PKOllamaProvider
import PKOpenAIProvider
import PKOpenRouterProvider
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
        // surface a structured error per turn. With a provider set, wire the
        // per-provider client factory so the LLM service can actually create
        // a transport client for the active provider.
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

extension LLMService {
    /// Returns a model configured from a PK LLM configuration, wiring the
    /// provider's client factory so the active provider resolves to a real
    /// transport client instead of `clientNotResolved`.
    static func configured(from configuration: LLMConfiguration) -> any LanguageModel {
        LLMService(
            configuration: configuration,
            clientFactory: { config in
                let provider = config.activeProvider
                switch provider {
                case .openAI, .openAICompatible:
                    let client = PKOpenAIProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
                    return (client, nil, nil)
                case .openRouter:
                    let client = PKOpenRouterProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
                    return (client, nil, nil)
                case .ollama:
                    let client = PKOllamaProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
                    return (client, nil, nil)
                case .anthropic:
                    let client = PKAnthropicProvider.makeClientAndRegisterStructuredOutputAdapter(configuration: config)
                    return (client, nil, nil)
                }
            }
        )
    }
}

