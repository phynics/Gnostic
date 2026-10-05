// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticPositronicAtlas
import PKContracts
import PositronicKit
import Synchronization
import Testing

@testable import GnosticHost

/// Behavioral evidence for GNO-PLAT-021 (#449): Atlas registers as one
/// compiled-in module, an Ascendant opts in through the backend-owned
/// `extensions` setting, and that one selection installs both the Positronic
/// Turn context source and the terminal Turn Shard Report recorder.
@Suite("Atlas module")
@MainActor
struct AtlasModuleTests {
    private let ascendantID = UUID(uuidString: "A1210000-0000-4000-8000-000000000101")!
    private let timelineID = UUID(uuidString: "A1210000-0000-4000-8000-000000000102")!

    @Test("the compiled-in Atlas descriptor names a runnable registry entry")
    func descriptorMatchesRunnableRegistryEntry() throws {
        let registryID = try #require(AtlasModule.value.registryID)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(
            contentsOf: root.appendingPathComponent("Documentation/Architecture/experiments.json")
        )
        let document = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let modules = try #require(document["modules"] as? [[String: Any]])
        let entry = try #require(modules.first { $0["id"] as? String == registryID })

        #expect(registryID == "GNO-MOD-ATLAS")
        #expect(entry["runnable"] as? Bool == true)
        #expect((entry["owningIssue"] as? String)?.contains("/449") == true)
    }

    @Test("an Ascendant that selects atlas installs its contribution and one recorder")
    func selectingAscendantInstallsContributionAndRecorder() async throws {
        let factory = AtlasStoreFactory()
        let module = AtlasModule.make(storeFactory: { factory.make($0) })
        let ascendant = atlasAscendant()

        let contributions = try BackendComposition.contributions(
            for: ascendant,
            backend: ascendant.backend,
            modules: ["atlas": module]
        )
        #expect(contributions.map(\.label) == ["atlas.turn"])
        #expect(contributions.first?.turnContextSource() != nil)

        #expect(module.terminalTurnObservers.count == 1)
        let scope = GnosticModuleScope(ascendant: ascendant, name: "atlas", settings: [:], secrets: [:])
        let makeObserver = try #require(module.terminalTurnObservers.first)
        let observer = makeObserver(scope)

        // Delivering one terminal Turn through the descriptor's recorder
        // appends exactly one report to the module's own store.
        try await observer.observe(TerminalTurnRecord(
            operationID: "atlas-operation-1",
            ascendantID: ascendantID,
            timelineID: timelineID,
            clientTurnID: nil,
            outcome: .succeeded
        ))

        let store = try #require(factory.store(for: ascendantID))
        let reports = await store.pendingReports()
        #expect(reports.count == 1)
        #expect(reports.first?.shardID == AscendantShardID(ascendantID))
        #expect(reports.first?.provenance.origin == .ascendantTurn)
    }

    @Test("an Ascendant that does not select atlas installs nothing")
    func absentSelectionInstallsNothing() throws {
        let module = AtlasModule.make(storeFactory: { ascendant in
            InMemoryAtlasStore(ascendantID: ascendant.id)
        })
        let plain = NodeManifest.Ascendant(
            id: UUID(),
            name: "Plain",
            defaultTimelineID: UUID(),
            backend: .init(kind: "positronic")
        )

        let contributions = try BackendComposition.contributions(
            for: plain,
            backend: plain.backend,
            modules: ["atlas": module]
        )

        #expect(contributions.isEmpty)
        #expect(BackendComposition.default.makeAdapters(for: [plain]).terminalTurnObservers.isEmpty)
    }

    @Test("the production composition installs the Atlas recorder only for selecting Ascendants")
    func productionSelectionScopesRecorder() {
        let selecting = atlasAscendant()
        let plain = NodeManifest.Ascendant(
            id: UUID(),
            name: "Plain",
            defaultTimelineID: UUID(),
            backend: .init(kind: "positronic")
        )

        #expect(BackendComposition.default.registeredPositronicExtensions.contains("atlas"))
        #expect(BackendComposition.default.makeAdapters(for: [selecting]).terminalTurnObservers.count == 1)
        #expect(BackendComposition.default.makeAdapters(for: [plain]).terminalTurnObservers.isEmpty)
    }

    @Test("a real Turn flows through the Atlas descriptor into a report and a projected brief")
    func turnEndToEndThroughDescriptor() async throws {
        let factory = AtlasStoreFactory()
        let module = AtlasModule.make(storeFactory: { factory.make($0) })
        let ascendant = atlasAscendant()

        // Prime the shared store with one home Shard and one item. The module's
        // lazy runtime later returns this same store, so the brief the
        // descriptor projects is the state the test seeded.
        let store = factory.make(ascendant)
        _ = try await store.register(AscendantShard(
            id: AscendantShardID(ascendantID),
            ascendantID: ascendantID,
            name: ascendant.name,
            kind: .home
        ))
        try await seed(store, key: "atlas.end-to-end-note", ascendantID: ascendantID)

        let contributions = try BackendComposition.contributions(
            for: ascendant,
            backend: ascendant.backend,
            modules: ["atlas": module]
        )
        let scope = GnosticModuleScope(ascendant: ascendant, name: "atlas", settings: [:], secrets: [:])
        let makeObserver = try #require(module.terminalTurnObservers.first)
        let moduleObserver = makeObserver(scope)

        let model = AtlasScriptedModel()
        let adapter = try await PositronicAscendantAdapter(
            ascendant: ascendant,
            backend: .init(kind: "positronic"),
            services: .empty,
            timelines: [NodeManifest.Timeline(id: timelineID, title: "Default", operatingAscendantID: ascendantID)],
            languageModel: model,
            contributions: contributions
        )
        let probe = AtlasTerminalProbe()
        let coordinator = AscendantTurnCoordinator(observers: [moduleObserver, probe])

        let first = try await coordinator.execute(
            AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: "atlas-turn-1"),
            ascendantID: ascendantID
        ) {
            try await adapter.runTurn(
                AscendantBackendTurnRequest(timelineID: timelineID, message: "hello", clientTurnID: "atlas-turn-1"),
                updates: AtlasNoopUpdateSink()
            )
        }
        let firstRecord = try #require(await probe.next())
        #expect(first.text == "atlas-reply")

        var reports = await store.pendingReports()
        #expect(reports.count == 1)
        #expect(reports.first?.operationID == AtlasOperationID(firstRecord.operationID))

        // The descriptor's context source projected the seeded item into the
        // prompt before the model ran.
        var prompt = await model.capturedPromptText()
        #expect(prompt.contains("<<<atlas-brief>>>"))
        #expect(prompt.contains("atlas.end-to-end-note"))

        _ = try await coordinator.execute(
            AscendantTurnRequest(message: "again", timelineID: timelineID, clientTurnID: "atlas-turn-2"),
            ascendantID: ascendantID
        ) {
            try await adapter.runTurn(
                AscendantBackendTurnRequest(timelineID: timelineID, message: "again", clientTurnID: "atlas-turn-2"),
                updates: AtlasNoopUpdateSink()
            )
        }
        _ = try #require(await probe.next())

        prompt = await model.capturedPromptText()
        #expect(prompt.contains("atlas.end-to-end-note"))

        reports = await store.pendingReports()
        #expect(reports.count == 2)
    }

    private func atlasAscendant() -> NodeManifest.Ascendant {
        NodeManifest.Ascendant(
            id: ascendantID,
            name: "Atlas Fixture",
            defaultTimelineID: timelineID,
            backend: .init(kind: "positronic", settings: ["extensions": .array([.string("atlas")])])
        )
    }

    private func seed(_ store: any AtlasStore, key: String, ascendantID: UUID) async throws {
        let shardID = AscendantShardID(ascendantID)
        let capture = await store.capture()
        _ = try await store.compareAndSwap(
            capture: capture,
            patch: AtlasPatch(
                id: AtlasPatchID("seed-\(UUID().uuidString.lowercased())"),
                capture: capture,
                operations: [.upsertItem(AtlasItem(
                    ascendantID: ascendantID,
                    sourceShardID: shardID,
                    key: key,
                    value: .text("Prefer the descriptor seam."),
                    kind: .preference,
                    applicability: .ascendant,
                    disclosure: .ascendant,
                    epistemicStatus: .reported,
                    provenance: AtlasProvenance(
                        ascendantID: ascendantID,
                        shardID: shardID,
                        origin: .host
                    )
                ))],
                provenance: AtlasProvenance(ascendantID: ascendantID, shardID: shardID, origin: .host)
            )
        )
    }
}

/// A synchronous store factory that retains one store per Ascendant, so a test
/// can inspect the state the module wrote and seed it before the first Turn.
private final class AtlasStoreFactory: Sendable {
    private let stores = Mutex<[UUID: any AtlasStore]>([:])

    func make(_ ascendant: NodeManifest.Ascendant) -> any AtlasStore {
        stores.withLock { stores in
            if let existing = stores[ascendant.id] { return existing }
            let store = InMemoryAtlasStore(ascendantID: ascendant.id)
            stores[ascendant.id] = store
            return store
        }
    }

    func store(for id: UUID) -> (any AtlasStore)? {
        stores.withLock { $0[id] }
    }
}

/// A minimal scripted model that captures the assembled prompt text.
private final class AtlasScriptedModel: LLMStreamClient, @unchecked Sendable {
    private let capture = AtlasPromptCapture()

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func capturedPromptText() async -> String { await capture.promptText }

    func generationStream(
        messages: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await capture.record(messages: messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMStreamChunk(
                id: "atlas-scripted",
                model: "atlas-scripted",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(content: "atlas-reply"),
                    finishReason: "stop"
                )]
            ))
            continuation.finish()
        }
    }
}

private actor AtlasPromptCapture {
    private(set) var promptText = ""

    func record(messages: [LLMMessage]) {
        promptText = messages.map(\.content).joined(separator: "\n")
    }
}

/// Waits for the coordinator's asynchronous observation delivery.
private actor AtlasTerminalProbe: TerminalTurnObserving {
    private(set) var records: [TerminalTurnRecord] = []
    private var readIndex = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func observe(_ record: TerminalTurnRecord) async throws {
        records.append(record)
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if records.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func next() async -> TerminalTurnRecord? {
        let target = readIndex + 1
        if records.count < target {
            await withCheckedContinuation { waiters.append((target, $0)) }
        }
        guard records.count >= target else { return nil }
        readIndex = target
        return records[target - 1]
    }
}

private struct AtlasNoopUpdateSink: AscendantBackendUpdateSink {
    func append(_: AscendantBackendUpdate) async throws {}
}
