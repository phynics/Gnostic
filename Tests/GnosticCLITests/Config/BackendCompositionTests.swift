// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticLettaBackend
import Testing

@testable import GnosticCLI

/// A minimal backend that proves a compiled-in kind is buildable through the
/// shared composition source. It implements the mandatory contract and nothing
/// else.
@MainActor
private final class FixtureCompositionBackend: AscendantBackend {
    let identity: AscendantBackendIdentity
    private var timelines: [AscendantBackendTimeline]

    init(ascendant: NodeManifest.Ascendant, timelines: [NodeManifest.Timeline]) {
        let now = Date()
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: AscendantBackendCapabilities(
                interoperability: [AscendantInteroperabilityCapability.textTurn.rawValue],
                backendKind: ascendant.backend.kind
            )
        )
        self.timelines = timelines.map {
            AscendantBackendTimeline(
                id: $0.id, title: $0.title, attachedWorkspaceIDs: [], ascendantID: ascendant.id,
                isArchived: false, isPrivate: false, createdAt: now, updatedAt: now
            )
        }
    }

    func validateConfiguration() throws {}

    func operatedTimelines() async throws -> [AscendantBackendTimeline] { timelines }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        let timeline = AscendantBackendTimeline(
            id: id, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id,
            isArchived: false, isPrivate: false, createdAt: now, updatedAt: now
        )
        timelines.append(timeline)
        return timeline
    }

    func removeTimeline(id: UUID) async { timelines.removeAll { $0.id == id } }

    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        let current = timelines[index]
        let renamed = AscendantBackendTimeline(
            id: current.id, title: title, attachedWorkspaceIDs: current.attachedWorkspaceIDs,
            ascendantID: current.ascendantID, isArchived: current.isArchived,
            isPrivate: current.isPrivate, createdAt: current.createdAt, updatedAt: Date()
        )
        timelines[index] = renamed
        return renamed
    }

    func runTurn(
        _ request: AscendantBackendTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String {
        let reply = "fixture: \(request.message)"
        try await updates.append(
            AscendantBackendUpdate(kind: AscendantTurnUpdateKind.assistantText.rawValue, text: reply)
        )
        return reply
    }

    func cancel() async {}

    func shutdown() async {}
}

/// Records whether a composition factory was invoked. Listing must never call
/// it.
@MainActor
private final class FixtureConstructionRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

@Suite("Backend composition source")
struct BackendCompositionTests {
    private static let fixtureKind = "fixture"
    private static let fixtureSchema = AscendantBackendSettingsSchema(keys: [
        .init(name: "endpoint", summary: "Fixture endpoint."),
        .init(name: "token", summary: "Fixture token.", isSecret: true),
    ])

    private func fixtureComposition(
        recorder: FixtureConstructionRecorder? = nil
    ) -> BackendComposition {
        var composition = BackendComposition()
        composition.registerBackend(kind: Self.fixtureKind, settings: Self.fixtureSchema) { ascendant, _, _, timelines in
            recorder?.record()
            return FixtureCompositionBackend(ascendant: ascendant, timelines: timelines)
        }
        return composition
    }

    private func seeded() throws -> (TemporaryFolder, CLIConfigurationStore) {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        return (folder, store)
    }

    @Test("one composition source exposes a fixture kind to config keys")
    func configListsFixtureKindKeys() throws {
        let (_, store) = try seeded()
        let composition = fixtureComposition()

        try ConfigCommandLogic.addAscendant(
            name: "Fixture", description: "", kind: Self.fixtureKind,
            store: store, composition: composition
        )
        let ascendantID = try #require(try store.loadManifest().ascendants.last?.id)

        var output: [String] = []
        try ConfigCommandLogic.listBackendKeys(
            ascendantID: ascendantID.uuidString, store: store, composition: composition,
            writeOutput: { output.append($0) }
        )

        let text = output.joined(separator: "\n")
        #expect(text.contains("kind: fixture"))
        #expect(text.contains("endpoint"))
        #expect(text.contains("token"))
        #expect(text.contains("[secret]"))
    }

    @Test("the fixture backend builds through the adapters serve uses")
    @MainActor
    func serveBuildsFixtureKind() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000A01")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000A02")!
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1, namespace: "composition-fixture"),
            node: .init(id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000A03")!),
            ascendants: [.init(
                id: ascendantID, name: "Fixture", defaultTimelineID: timelineID,
                backend: .init(kind: Self.fixtureKind)
            )],
            timelines: [.init(id: timelineID, title: "Fixture Timeline", operatingAscendantID: ascendantID)]
        )

        let composition = fixtureComposition()
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: composition.makeAdapters()
        )

        let snapshot = await runtime.snapshot()
        #expect(snapshot.ascendantIDs == [ascendantID])
        await runtime.shutdown()
    }

    @Test("listing kinds and schemas never constructs a backend")
    @MainActor
    func listingDoesNotConstructBackends() {
        let recorder = FixtureConstructionRecorder()
        let composition = fixtureComposition(recorder: recorder)

        #expect(composition.registeredKinds.contains(Self.fixtureKind))
        let schema = composition.settingsSchema(for: Self.fixtureKind)
        #expect(schema?.settingNames == ["endpoint"])
        #expect(schema?.secretNames == ["token"])
        #expect(recorder.count == 0)
    }

    @Test("the production composition exposes Positronic, Letta, and ACP without building a model")
    func productionCompositionListsBackends() {
        let composition = BackendComposition.default
        #expect(composition.registeredKinds == [
            AscendantAdapterRegistry.positronicKind,
            LettaAscendantBackend.kind,
            "acp-client",
        ])
        let schema = composition.settingsSchema(for: AscendantAdapterRegistry.positronicKind)
        #expect(schema?.settingNames == ["provider", "endpoint", "model", "utilityModel", "fastModel", "extensions", "rlm.worker"])
        let lettaSchema = composition.settingsSchema(for: LettaAscendantBackend.kind)
        #expect(lettaSchema?.settingNames == ["serverURL", "model", "agentID", "agentName", "maxSteps"])
        #expect(lettaSchema?.secretNames == ["apiKey"])

        let acpSchema = composition.settingsSchema(for: "acp-client")
        #expect(acpSchema?.settingNames == ["command", "args", "cwd", "env", "displayName"])
        #expect(acpSchema?.secretNames == [])
    }

    @Test("an unregistered kind is still rejected")
    func unregisteredKindIsRejected() throws {
        let (_, store) = try seeded()
        let composition = fixtureComposition()

        #expect(throws: (any Error).self) {
            try ConfigCommandLogic.addAscendant(
                name: "Unknown", description: "", kind: "not-registered",
                store: store, composition: composition
            )
        }
    }
}
