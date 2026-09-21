// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import JSONSchema
import PKContracts
import PositronicKit
import Synchronization
import Testing

@testable import GnosticCLI

@Suite("Per-Ascendant Positronic extension selection")
struct PositronicExtensionSelectionTests {
    // MARK: - Startup rejection

    @Test("an unknown extension fails startup before advertisement and names the extension")
    @MainActor
    func unknownExtensionFailsStartup() async throws {
        let ascendantID = UUID()
        let timelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1, namespace: "extension-unknown"),
            node: .init(id: UUID()),
            ascendants: [.init(
                id: ascendantID,
                name: "Unknown Extension",
                defaultTimelineID: timelineID,
                backend: .init(
                    kind: "positronic",
                    settings: ["extensions": .array([.string("missing-extension")])]
                )
            )],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )

        do {
            let runtime = try await NodeRuntime(
                plan: manifest.compileLaunchPlan(),
                adapters: BackendComposition.default.makeAdapters()
            )
            await runtime.shutdown()
            Issue.record("NodeRuntime accepted an unknown Positronic extension.")
        } catch let error as AscendantBackendError {
            #expect(error.reasonCode == "invalidConfiguration")
            #expect(error.localizedDescription.contains("missing-extension"))
        }
    }

    @Test("a malformed extensions value fails startup")
    @MainActor
    func malformedExtensionsValueFailsStartup() throws {
        let ascendant = makeAscendant(name: "Malformed")
        let backend = NodeManifest.BackendConfiguration(
            kind: "positronic",
            settings: ["extensions": .string("fixture")]
        )

        #expect(throws: AscendantBackendError.self) {
            _ = try BackendComposition.contributions(
                for: ascendant,
                backend: backend,
                extensions: ["fixture": fixtureExtension()]
            )
        }
    }

    @Test("a duplicate extension selection fails startup")
    @MainActor
    func duplicateSelectionFailsStartup() throws {
        let ascendant = makeAscendant(name: "Duplicate")
        let backend = NodeManifest.BackendConfiguration(
            kind: "positronic",
            settings: ["extensions": .array([.string("fixture"), .string("fixture")])]
        )

        #expect(throws: AscendantBackendError.self) {
            _ = try BackendComposition.contributions(
                for: ascendant,
                backend: backend,
                extensions: ["fixture": fixtureExtension()]
            )
        }
    }

    // MARK: - Per-Ascendant selection

    @Test("two Positronic Ascendants on one Node select different extension sets")
    @MainActor
    func twoAscendantsSelectDifferentExtensions() async throws {
        let probe = FixtureExtensionProbe()
        var composition = BackendComposition()
        composition.registerPositronicExtension(fixtureExtension(probe: probe))

        let selectingID = UUID()
        let selectingTimelineID = UUID()
        let plainID = UUID()
        let plainTimelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1, namespace: "extension-selection"),
            node: .init(id: UUID()),
            ascendants: [
                .init(
                    id: selectingID,
                    name: "With Extension",
                    defaultTimelineID: selectingTimelineID,
                    backend: .init(
                        kind: "positronic",
                        settings: ["extensions": .array([.string("fixture")])]
                    )
                ),
                .init(id: plainID, name: "Plain", defaultTimelineID: plainTimelineID),
            ],
            timelines: [
                .init(id: selectingTimelineID, title: "Extension", operatingAscendantID: selectingID),
                .init(id: plainTimelineID, title: "Plain", operatingAscendantID: plainID),
            ]
        )

        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: composition.makeAdapters()
        )
        let snapshot = await runtime.snapshot()
        await runtime.shutdown()

        #expect(Set(snapshot.ascendantIDs) == [selectingID, plainID])
        // Only the selecting Ascendant's extension factory ran, so only that
        // Ascendant received a contribution.
        #expect(probe.records.map(\.ascendantID) == [selectingID])
    }

    @Test("a selected extension's contribution reaches the Ascendant's tool surface")
    @MainActor
    func selectedContributionReachesAdapter() async throws {
        let ascendantID = UUID()
        let timelineID = UUID()
        let extensionValue = fixtureExtension(toolCallName: "fixture_analysis")
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "With Extension",
            defaultTimelineID: timelineID,
            backend: .init(
                kind: "positronic",
                settings: ["extensions": .array([.string("fixture")])]
            )
        )

        let contributions = try BackendComposition.contributions(
            for: ascendant,
            backend: ascendant.backend,
            extensions: ["fixture": extensionValue]
        )
        let adapter = try await PositronicAscendantAdapter(
            ascendant: ascendant,
            backend: ascendant.backend,
            services: .empty,
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)],
            languageModel: UnconfiguredLLMService(),
            contributions: contributions
        )

        #expect(await adapter.enabledToolIDs(for: timelineID).contains("fixture_analysis"))
    }

    @Test("extension settings are name-spaced per extension")
    @MainActor
    func extensionSettingsAreNamespaced() throws {
        let probe = FixtureExtensionProbe()
        let alpha = PositronicExtension(name: "alpha", settingKeys: [.init(name: "value", summary: "Alpha value.")]) { scope in
            probe.record(ascendantID: scope.ascendant.id, settings: scope.settings, secrets: scope.secrets)
            return FixtureContribution(label: "alpha")
        }
        let beta = PositronicExtension(name: "beta", settingKeys: [.init(name: "value", summary: "Beta value.")]) { scope in
            probe.record(ascendantID: scope.ascendant.id, settings: scope.settings, secrets: scope.secrets)
            return FixtureContribution(label: "beta")
        }
        let ascendant = makeAscendant(name: "Scoped")
        let backend = NodeManifest.BackendConfiguration(
            kind: "positronic",
            settings: [
                "extensions": .array([.string("alpha"), .string("beta")]),
                "alpha.value": .string("A"),
                "beta.value": .string("B"),
            ]
        )

        _ = try BackendComposition.contributions(
            for: ascendant,
            backend: backend,
            extensions: ["alpha": alpha, "beta": beta]
        )

        #expect(probe.records.count == 2)
        #expect(probe.records.compactMap { $0.settings["value"]?.stringValue } == ["A", "B"])
    }

    @Test("the selected extension receives only its Ascendant runtime context")
    @MainActor
    func runtimeContextIsScopedToSelectedAscendant() throws {
        let workspaceID = UUID()
        let ascendant = makeAscendant(name: "Scoped runtime")
        let backend = NodeManifest.BackendConfiguration(
            kind: "positronic",
            settings: ["extensions": .array([.string("fixture")])]
        )
        let runtime = PositronicContributionRuntimeContext(
            workspaceReader: nil,
            permission: AscendantBackendServices.empty.permission,
            modelService: nil,
            allowedWorkspaceIDs: [workspaceID]
        )
        let received = Mutex<Set<UUID>>([])
        let extensionValue = PositronicExtension(name: "fixture") { scope in
            received.withLock { $0 = scope.runtimeContext?.allowedWorkspaceIDs ?? [] }
            return FixtureContribution(label: "fixture")
        }

        _ = try BackendComposition.contributions(
            for: ascendant,
            backend: backend,
            extensions: ["fixture": extensionValue],
            runtimeContext: runtime
        )

        #expect(received.withLock { $0 } == [workspaceID])
    }

    // MARK: - Schema advertisement

    @Test("the Positronic schema advertises the selection key and name-spaced extension keys")
    func schemaAdvertisesExtensionKeys() {
        var composition = BackendComposition()
        composition.registerPositronicExtension(fixtureExtension())
        let schema = composition.settingsSchema(for: AscendantAdapterRegistry.positronicKind)

        #expect(composition.registeredPositronicExtensions == ["fixture"])
        #expect(schema?.settingNames.contains("extensions") == true)
        #expect(schema?.settingNames.contains("fixture.mode") == true)
        #expect(schema?.secretNames.contains("fixture.token") == true)
    }

    @Test("config backend keys lists the extension selection and each extension's keys")
    func configListsExtensionKeys() throws {
        let (_, store) = try seeded()
        var composition = BackendComposition()
        composition.registerPositronicExtension(fixtureExtension())
        let id = try #require(try store.loadManifest().ascendants.first?.id)

        var output: [String] = []
        try ConfigCommandLogic.listBackendKeys(
            ascendantID: id.uuidString,
            store: store,
            composition: composition,
            writeOutput: { output.append($0) }
        )

        let text = output.joined(separator: "\n")
        #expect(text.contains("extensions"))
        #expect(text.contains("fixture.mode"))
        #expect(text.contains("fixture.token"))
        #expect(text.contains("[secret]"))
    }

    // MARK: - Secret handling

    @Test("an extension secret is stored in secrets and never printed")
    func extensionSecretIsStoredAndRedacted() throws {
        let (_, store) = try seeded()
        var composition = BackendComposition()
        composition.registerPositronicExtension(fixtureExtension())
        let id = try #require(try store.loadManifest().ascendants.first?.id)

        try ConfigCommandLogic.setBackendSecret(
            ascendantID: id.uuidString,
            key: "fixture.token",
            value: "sk-fixture-hidden",
            store: store,
            composition: composition
        )

        let backend = try store.loadManifest().ascendants[0].backend
        #expect(backend.secrets["fixture.token"]?.stringValue == "sk-fixture-hidden")
        #expect(backend.settings["fixture.token"] == nil)
        #expect(throws: (any Error).self) {
            try ConfigCommandLogic.setBackendValue(
                ascendantID: id.uuidString,
                key: "fixture.token",
                value: "leak",
                store: store,
                composition: composition
            )
        }

        var output: [String] = []
        try ConfigCommandLogic.show(store: store, writeOutput: { output.append($0) })
        let text = output.joined(separator: "\n")
        #expect(!text.contains("sk-fixture-hidden"))
        #expect(text.contains("<redacted>"))
    }

    // MARK: - Absent mode

    @Test("an Ascendant without the extensions key resolves no contributions")
    @MainActor
    func absentSelectionResolvesNothing() throws {
        let ascendant = makeAscendant(name: "Plain")

        let contributions = try BackendComposition.contributions(
            for: ascendant,
            backend: .init(kind: "positronic"),
            extensions: ["fixture": fixtureExtension()]
        )

        #expect(contributions.isEmpty)
    }

    @Test("the default composition registers RLM without selecting it")
    func defaultRLMIsOptIn() {
        let composition = BackendComposition.default
        #expect(composition.registeredPositronicExtensions.contains("rlm"))
        #expect(composition.settingsSchema(for: AscendantAdapterRegistry.positronicKind)?.settingNames.contains("rlm.worker") == true)
    }

    @Test("an existing manifest without the key behaves exactly as today")
    @MainActor
    func existingManifestIsUnchanged() async throws {
        let manifest = NodeManifest.makeDefault(
            broker: .init(host: "127.0.0.1", port: 1, namespace: "extension-absent")
        )

        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: BackendComposition.default.makeAdapters()
        )
        let snapshot = await runtime.snapshot()
        await runtime.shutdown()

        #expect(snapshot.ascendantIDs.count == 1)
    }

    // MARK: - Helpers

    private func seeded() throws -> (TemporaryFolder, CLIConfigurationStore) {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        return (folder, store)
    }

    private func makeAscendant(name: String) -> NodeManifest.Ascendant {
        NodeManifest.Ascendant(id: UUID(), name: name, defaultTimelineID: UUID())
    }

    private func fixtureExtension(
        probe: FixtureExtensionProbe? = nil,
        toolCallName: String = "fixture_tool"
    ) -> PositronicExtension {
        PositronicExtension(
            name: "fixture",
            settingKeys: [
                .init(name: "mode", summary: "Fixture mode."),
                .init(name: "token", summary: "Fixture token.", isSecret: true),
            ]
        ) { scope in
            probe?.record(
                ascendantID: scope.ascendant.id,
                settings: scope.settings,
                secrets: scope.secrets
            )
            return FixtureContribution(
                label: "fixture",
                tools: [AnyTool(FixtureTool(callName: toolCallName))]
            )
        }
    }
}

// MARK: - Fixtures

/// Records one extension factory invocation with its scoped configuration.
private final class FixtureExtensionProbe: Sendable {
    struct Record: Sendable {
        let ascendantID: UUID
        let settings: [String: ManifestJSONValue]
        let secrets: [String: ManifestJSONValue]
    }

    private let storage = Mutex<[Record]>([])

    func record(
        ascendantID: UUID,
        settings: [String: ManifestJSONValue],
        secrets: [String: ManifestJSONValue]
    ) {
        storage.withLock {
            $0.append(Record(ascendantID: ascendantID, settings: settings, secrets: secrets))
        }
    }

    var records: [Record] { storage.withLock { $0 } }
}

private struct FixtureContribution: PositronicContribution {
    let label: String
    private let toolList: [AnyTool]

    init(label: String, tools: [AnyTool] = []) {
        self.label = label
        toolList = tools
    }

    func tools() -> [AnyTool] { toolList }
}

private struct FixtureTool: PKTool, Sendable {
    let callName: String

    var identity: ToolReference { .known(id: callName) }
    var name: String { callName }
    var toolDescription: String { "Fixture tool \(callName)." }
    var requiresPermission: Bool { false }
    var sideEffects: ToolSideEffects { .none }
    var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }
    func canExecute() async -> Bool { true }
    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult { .success(callName) }
}
