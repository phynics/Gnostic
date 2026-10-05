// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI
@testable import GnosticHost

/// Behavioral evidence for GNO-PLAT-020 (#448): one compiled-in module
/// descriptor registers its contribution and its terminal Turn observers, and
/// the composition installs an observer only for the Ascendants that select it.
@Suite("Module descriptor registration")
struct GnosticModuleRegistrationTests {
    @Test("a selecting Ascendant installs the module observer, scoped to it")
    func selectingAscendantInstallsScopedObserver() async throws {
        let recorder = ModuleObserverRecorder()
        var composition = BackendComposition()
        composition.registerModule(fixtureModule(observer: recorder))

        let selectingID = UUID()
        let plainID = UUID()
        let selectingTimelineID = UUID()
        let plainTimelineID = UUID()
        let ascendants: [NodeManifest.Ascendant] = [
            .init(
                id: selectingID,
                name: "Probe",
                defaultTimelineID: selectingTimelineID,
                backend: .init(
                    kind: "positronic",
                    settings: ["extensions": .array([.string("probe")])]
                )
            ),
            .init(id: plainID, name: "Plain", defaultTimelineID: plainTimelineID),
        ]

        let adapters = composition.makeAdapters(for: ascendants)
        #expect(adapters.terminalTurnObservers.count == 1)
        let observer = try #require(adapters.terminalTurnObservers.first)

        try await observer.observe(
            .init(
                operationID: "op-selecting",
                ascendantID: selectingID,
                timelineID: selectingTimelineID,
                clientTurnID: "selecting",
                outcome: .succeeded
            )
        )
        try await observer.observe(
            .init(
                operationID: "op-plain",
                ascendantID: plainID,
                timelineID: plainTimelineID,
                clientTurnID: "plain",
                outcome: .succeeded
            )
        )

        // The wrapper dropped the record that belonged to the non-selecting
        // Ascendant, so a shared observer cannot leak one Ascendant's Turn into
        // another.
        #expect(await recorder.records.map(\.ascendantID) == [selectingID])
    }

    @Test("an Ascendant that selects no module installs no observer")
    func absentSelectionInstallsNoObserver() {
        var composition = BackendComposition()
        composition.registerModule(fixtureModule(observer: ModuleObserverRecorder()))
        let ascendant = NodeManifest.Ascendant(id: UUID(), name: "Plain", defaultTimelineID: UUID())

        let adapters = composition.makeAdapters(for: [ascendant])

        #expect(adapters.terminalTurnObservers.isEmpty)
    }

    @Test("the no-argument adapter builder installs no module observer")
    func noArgumentBuilderInstallsNoObserver() {
        var composition = BackendComposition()
        composition.registerModule(fixtureModule(observer: ModuleObserverRecorder()))

        #expect(composition.makeAdapters().terminalTurnObservers.isEmpty)
    }

    @Test("a module without a contribution is registered but not advertised as a Positronic extension")
    func moduleWithoutContributionIsNotAnExtension() {
        var composition = BackendComposition()
        composition.registerModule(fixtureModule(observer: ModuleObserverRecorder()))

        #expect(composition.registeredModules == ["probe"])
        #expect(composition.registeredPositronicExtensions.isEmpty)
    }

    @Test("a module descriptor exposes its optional experiment subcommand")
    func moduleExposesExperimentSubcommand() {
        let module = GnosticModule(
            name: "rlm",
            experimentSubcommand: .init(name: "rlm-scenario", abstract: "Run the RLM scenario.")
        )

        #expect(
            module.experimentSubcommand
                == GnosticModuleSubcommand(name: "rlm-scenario", abstract: "Run the RLM scenario.")
        )
    }

    @Test("the compiled-in RLM descriptor names a registry entry that exists")
    func rlmDescriptorMatchesRegistry() throws {
        let registryID = try #require(RLMModule.value.registryID)
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

        #expect(registryID == "GNO-MOD-RLM")
        #expect(modules.contains { $0["id"] as? String == registryID })
    }

    private func fixtureModule(observer: ModuleObserverRecorder) -> GnosticModule {
        GnosticModule(
            name: "probe",
            settingKeys: [.init(name: "value", summary: "Probe value.")],
            terminalTurnObservers: [{ _ in observer }]
        )
    }
}

private actor ModuleObserverRecorder: TerminalTurnObserving {
    private(set) var records: [TerminalTurnRecord] = []

    func observe(_ record: TerminalTurnRecord) async throws {
        records.append(record)
    }
}
