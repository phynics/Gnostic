// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("ACP transport selection")
struct ACPTransportSelectionTests {
    @Test("Ascendant selection requires stable text-turn capability")
    @MainActor
    func selectionRequiresStableTextTurnCapability() throws {
        let timelineID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000021")!
        let incapable = RemoteTurnClient.DiscoveredAscendant(
            id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000022")!,
            name: "Experimental",
            timelineID: timelineID,
            providerID: "provider-a",
            capabilities: ["x-example.future-turn-mode"]
        )
        let capable = RemoteTurnClient.DiscoveredAscendant(
            id: UUID(uuidString: "C41D0000-0000-4000-8000-000000000023")!,
            name: "Text Ascendant",
            timelineID: timelineID,
            providerID: "provider-b",
            capabilities: ["x-example.future-turn-mode", GnosticCapability.textTurnInput]
        )

        let selected = try RemoteTurnClient.selectCandidate(from: [incapable, capable])
        #expect(selected.id == capable.id)
        #expect(selected.capabilities.contains("x-example.future-turn-mode"))

        do {
            _ = try RemoteTurnClient.selectCandidate(from: [incapable])
            Issue.record("an Ascendant without textTurnInput was selected")
        } catch let error as RemoteTurnClientError {
            #expect(error.gnosticCode == "missingCapability")
        }
    }

    @Test("node selection resolves a duplicated Ascendant across serve restarts")
    @MainActor
    func nodeSelectionResolvesDuplicatedAscendant() throws {
        let ascendantID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000031")!
        let firstNodeID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000041")!
        let secondNodeID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000042")!
        func candidate(providerID: String, nodeID: UUID?) -> RemoteTurnClient.DiscoveredAscendant {
            RemoteTurnClient.DiscoveredAscendant(
                id: ascendantID,
                name: "Shared Ascendant",
                timelineID: UUID(uuidString: "C41D0000-0000-4000-8000-000000000051")!,
                providerID: providerID,
                nodeID: nodeID,
                capabilities: [GnosticCapability.textTurnInput]
            )
        }
        let candidates = [
            candidate(providerID: "provider-a", nodeID: firstNodeID),
            candidate(providerID: "provider-b", nodeID: secondNodeID),
        ]

        // The Ascendant ID alone stays ambiguous; the node resolves it, and the
        // provider that answers is whatever the live serve process advertises.
        #expect(throws: RemoteTurnClientError.self) {
            try RemoteTurnClient.selectCandidate(from: candidates, id: ascendantID)
        }
        #expect(try RemoteTurnClient.selectCandidate(
            from: candidates,
            id: ascendantID,
            nodeID: secondNodeID
        ).providerID == "provider-b")

        // After a restart the same node answers under a new provider identity.
        #expect(try RemoteTurnClient.selectCandidate(
            from: [candidate(providerID: "provider-c", nodeID: secondNodeID)],
            id: ascendantID,
            nodeID: secondNodeID
        ).providerID == "provider-c")

        do {
            _ = try RemoteTurnClient.selectCandidate(
                from: candidates,
                id: ascendantID,
                nodeID: UUID(uuidString: "C41D0000-0000-4000-8000-000000000043")!
            )
            Issue.record("an unadvertised node was selected")
        } catch let error as RemoteTurnClientError {
            #expect(error.gnosticCode == "nodeUnavailable")
        }

        // A serve older than the node property stays addressable by Ascendant.
        #expect(try RemoteTurnClient.selectCandidate(
            from: [candidate(providerID: "provider-legacy", nodeID: nil)],
            id: ascendantID,
            nodeID: firstNodeID
        ).providerID == "provider-legacy")
    }

    @Test("an evicted provider reports a typed offline error")
    @MainActor
    func evictedProviderReportsTypedOfflineError() {
        let error = RemoteTurnClientError.providerOffline("A21D0000-0000-4000-8000-000000000099")
        #expect(error.gnosticCode == "providerOffline")
        #expect(error.errorDescription == "Provider a21d0000-0000-4000-8000-000000000099 went offline.")
    }
}

@Suite("ACP provider offline", .serialized)
struct ACPProviderOfflineTests {
    @Test(
        "graceful serve stop evicts the provider and fails later calls fast",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func gracefulStopEvictsProviderAndFailsCallsFast() async throws {
        let namespace = "acp-provider-offline-\(UUID().uuidString.lowercased())"
        let ascendantID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000031")!
        let timelineID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000032")!
        let hangingModel = HangingLanguageModel()
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerPositronicBackend { _, _ in hangingModel }
        let runtime = try await NodeRuntime(
            plan: try offlineManifest(
                namespace: namespace,
                nodeID: "C41D0000-0000-4000-8000-000000000030",
                ascendantID: ascendantID,
                timelineID: timelineID
            ).compileLaunchPlan(),
            adapters: adapters
        )
        defer {
            Task { @MainActor in await runtime.shutdown() }
        }

        // Connect the long-lived client before the provider starts so it
        // observes the lifecycle identity advertisement. Axoloty only delivers
        // a deadvertise for an object whose advertisement the subscriber saw.
        let client = try RemoteTurnClient(
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            timeout: .seconds(5),
            promptTimeout: .seconds(20)
        )
        defer {
            Task { @MainActor in await client.stop() }
        }
        try await client.connect()

        try await runtime.start()

        let clock = ContinuousClock()
        let selectionDeadline = clock.now + .seconds(8)
        var selected: RemoteTurnClient.DiscoveredAscendant?
        while clock.now < selectionDeadline, selected == nil {
            selected = try? await client.selectAscendant(id: ascendantID)
            if selected == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let ascendant = try #require(selected)

        let timeline = try await client.createTimeline(
            title: "Eviction",
            ascendantID: ascendant.id,
            providerID: ascendant.providerID
        )
        // Keep a Turn in flight against a backend that never finishes.
        let pendingTurn = Task {
            try await client.turn(
                message: "hang",
                timelineID: timeline.timelineID,
                clientTurnID: "eviction:turn-1",
                providerID: ascendant.providerID
            )
        }
        await hangingModel.waitUntilTurnStarts()

        // A graceful stop publishes the lifecycle identity deadvertise.
        let evictionStart = Date()
        await runtime.shutdown()

        let pendingStart = Date()
        do {
            _ = try await pendingTurn.value
            Issue.record("a pending call to a stopped provider succeeded")
        } catch {
            // The serve cancels the in-flight Turn and answers before the
            // identity deadvertise is delivered, so this is a typed remote
            // failure rather than providerOffline. The requirement is that it
            // settles quickly instead of waiting for the prompt timeout.
        }
        #expect(Date().timeIntervalSince(pendingStart) < 8)

        let evictionDeadline = Date().addingTimeInterval(8)
        while Date() < evictionDeadline,
              !client.evictedProviderIDs.contains(ascendant.providerID.lowercased()) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(client.evictedProviderIDs.contains(ascendant.providerID.lowercased()))

        // A later call must fail from local liveness state without a discover
        // round trip or the prompt timeout.
        let laterStart = Date()
        do {
            _ = try await client.turn(
                message: "later",
                timelineID: timeline.timelineID,
                clientTurnID: "eviction:turn-2",
                providerID: ascendant.providerID
            )
            Issue.record("a later call to an evicted provider succeeded")
        } catch let error as RemoteTurnClientError {
            #expect(error.gnosticCode == "providerOffline")
        }
        #expect(Date().timeIntervalSince(laterStart) < 2)
        #expect(Date().timeIntervalSince(evictionStart) < 15)
    }
}

private func offlineManifest(
    namespace: String,
    nodeID: String,
    ascendantID: UUID,
    timelineID: UUID
) throws -> NodeManifest {
    let nodeID = try #require(UUID(uuidString: nodeID))
    return NodeManifest(
        broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
        node: .init(id: nodeID),
        ascendants: [.init(
            id: ascendantID,
            name: "Offline Ascendant",
            defaultTimelineID: timelineID,
            backend: .init(kind: "positronic", settings: ["provider": .string("Ollama"), "model": .string("deterministic")])
        )],
        timelines: [.init(id: timelineID, title: "Offline Timeline", operatingAscendantID: ascendantID)]
    )
}

/// Waits until a Turn reaches the language model.
private actor TurnStartGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signalEntered() {
        entered = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A backend whose Turn never finishes, so a remote call stays in flight until
/// its provider goes away.
private final class HangingLanguageModel: LLMStreamClient, @unchecked Sendable {
    private let gate = TurnStartGate()

    func waitUntilTurnStarts() async { await gate.waitUntilEntered() }

    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration { get async { .init(activeProvider: .openAI, providers: [:]) } }

    func chatStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await gate.signalEntered()
        return AsyncThrowingStream { _ in }
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, modelTier: modelTier)
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
    func generateTitle(for _: [Message]) async throws -> String { "offline" }
    func fetchAvailableModels() async throws -> [String]? { nil }
}
