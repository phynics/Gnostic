// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared
import PositronicKit
import Testing

@Suite("Serve runtime over the broker")
struct ServeRuntimeTests {
    @Test("serve offers network workspace tools to Ascendant turns") @MainActor
    func serveOffersNetworkWorkspaceToolsToAscendantTurns() async throws {
        let namespace = "serve-turn-tools-tests"
        let languageModel = ToolCaptureLanguageModel()
        let runtime = try await ServeRuntime(
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            approveMode: .auto,
            languageModel: languageModel
        )
        defer { runtime.shutdown() }
        try await runtime.start()

        let consumer = try ServeTestBroker.consumer(namespace: namespace)
        defer { consumer.stop() }
        try consumer.start()

        let request = AgentChatRequest(message: "find a workspace", timelineID: runtime.servedTimelineID)
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = try await consumer.call(
            operation: AgentChatProvider.chatOperation,
            parameters: payload,
            timeout: .seconds(3)
        )
        let result = try JSONDecoder().decode(
            AgentChatResult.self,
            from: Data(response.result.utf8)
        )
        #expect(result.text == "ready")
        #expect(await languageModel.toolNames().isSuperset(of: [
            "list_network_objects",
            "inspect_network_object",
            "attach_workspace",
        ]))
        #expect(await languageModel.toolNames().isDisjoint(with: [
            "Change Directory",
            "List Directory",
            "Find File",
            "Search File Content",
            "Search Files",
            "Read File",
        ]))
    }

    @Test("serve advertises its timeline and hosts the network operations") @MainActor
    func serveAdvertisesAndHostsOps() async throws {
        let namespace = "serve-runtime-tests"
        let runtime = try await ServeRuntime(host: "127.0.0.1", port: 1883, namespace: namespace, approveMode: .auto)
        defer { runtime.shutdown() }
        try await runtime.start()

        // Advertise the served objects.
        let agent = AgentInstance(name: "serve-tests", description: "test", privateTimelineID: runtime.servedTimelineID)
        await runtime.advertise(agent: agent, workspaces: [])

        // A consumer discovers the timeline through an active request.
        let consumer = try ServeTestBroker.consumer(namespace: namespace)
        defer { consumer.stop() }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }

        let timelineID = runtime.servedTimelineID
        // Start the consumer and issue the active discovery request.
        try consumer.start()
        await subscription.discover(using: consumer, timeout: .seconds(1))
        try await poll {
            let entries = await catalog.networkObjects()
            return entries.contains { $0.objectID == timelineID }
        }

        // The timeline.status operation resolves through the unary Call/Return.
        let request = TimelineStatusRequest(timelineID: timelineID)
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = try await consumer.call(
            operation: TimelineStatusProvider.statusOperation,
            parameters: payload,
            timeout: .seconds(3)
        )
        let status = try JSONDecoder().decode(
            TimelineStatus.self,
            from: Data(response.result.utf8)
        )
        #expect(status.timelineID == timelineID)
    }

    @Test("late discovery resolves one-shot served objects") @MainActor
    func lateDiscoveryResolvesOneShotServedObjects() async throws {
        let namespace = "serve-discovery-tests"
        let runtime = try await ServeRuntime(host: "127.0.0.1", port: 1883, namespace: namespace, approveMode: .auto)
        defer { runtime.shutdown() }
        try await runtime.start()
        let workspace = WorkspaceReference(
            uri: WorkspaceURI(parsing: "workspace://serve-discovery")!,
            location: .runtime,
            tools: [.custom(.init(id: "echo", name: "Echo", description: "Echoes input."))],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await runtime.advertise(
            agent: AgentInstance(name: "serve-discovery", description: "test", privateTimelineID: runtime.servedTimelineID),
            workspaces: [workspace]
        )

        let consumer = try ServeTestBroker.consumer(namespace: namespace)
        defer { consumer.stop() }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer)
        try await subscription.start()
        defer { subscription.stop() }
        try consumer.start()

        await subscription.discover(using: consumer, timeout: .seconds(1))
        let discoveredTypes = await Set(catalog.networkObjects().map(\.objectType))
        #expect(discoveredTypes == Set([
            GnosticObjectType.agent,
            GnosticObjectType.timeline,
            GnosticObjectType.workspace,
        ]))
    }

    @Test("serve does not heartbeat advertisements") @MainActor
    func serveDoesNotHeartbeatAdvertisements() async throws {
        let namespace = "serve-advertisement-tests"
        let runtime = try await ServeRuntime(host: "127.0.0.1", port: 1883, namespace: namespace, approveMode: .auto)
        defer { runtime.shutdown() }
        try await runtime.start()

        let consumer = try ServeTestBroker.consumer(namespace: namespace)
        defer { consumer.stop() }
        let stream = try await consumer.observeAdvertiseStream(withObjectType: GnosticObjectType.timeline)
        let events = Task { () -> [AdvertiseEventSnapshot] in
            var events: [AdvertiseEventSnapshot] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        try consumer.start()
        try await Task.sleep(for: .milliseconds(300))

        await runtime.advertise(
            agent: AgentInstance(name: "serve-advertisement", description: "test", privateTimelineID: runtime.servedTimelineID),
            workspaces: []
        )
        try await Task.sleep(for: .seconds(1))
        consumer.stop()
        events.cancel()

        #expect(await events.value.count == 1)
    }

    /// Polls a condition up to a bounded deadline.
    private func poll(what: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<50 {
            if await what() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }
}

/// Captures the tool definitions sent to an Ascendant's language model request.
final class ToolCaptureLanguageModel: LanguageModel, @unchecked Sendable {
    private let capture = ToolCapture()

    func toolNames() async -> Set<String> {
        await capture.names
    }

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func chatStream(
        messages _: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await capture.record(tools: tools ?? [])
        let chunk = LLMStreamChunk(
            id: "capture",
            model: "capture",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(content: "ready"),
                finishReason: "stop"
            )]
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(chunk)
            continuation.finish()
        }
    }

    private actor ToolCapture {
        private(set) var names: Set<String> = []

        func record(tools: [LLMToolDefinition]) {
            names = Set(tools.map(\.name))
        }
    }

    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}

    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { "ok" }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { "capture" }
    func evaluateRecallPerformance(
        transcript _: String,
        recalledMemories _: [Memory]
    ) async throws -> [String: Double] { [:] }
    func fetchAvailableModels() async throws -> [String]? { nil }
}

/// A broker consumer helper for serve tests.
@MainActor
enum ServeTestBroker {
    static func consumer(namespace: String) throws -> CommunicationManager {
        try CommunicationManager(
            identity: Identity(name: "serve-tests-consumer"),
            communicationOptions: .init(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: .init(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
    }
}
