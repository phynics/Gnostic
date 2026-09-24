// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

@Suite("ACP mixed configuration", .serialized)
struct ACPMixedConfigurationTests {
    @Test("config lists the ACP schema, accepts declared keys, and rejects unknown keys")
    func configUsesACPSettingsSchema() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        let composition = BackendComposition.default
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        try ConfigCommandLogic.addAscendant(
            name: "ACP",
            description: "External agent",
            kind: "acp-client",
            store: store,
            composition: composition
        )
        let id = try #require(try store.loadManifest().ascendants.last?.id)

        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString,
            key: "command",
            value: "fixture-agent",
            store: store,
            composition: composition
        )
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString,
            key: "env",
            value: #"{"MODE":"test"}"#,
            store: store,
            composition: composition
        )

        #expect(throws: (any Error).self) {
            try ConfigCommandLogic.setBackendValue(
                ascendantID: id.uuidString,
                key: "commnad",
                value: "typo",
                store: store,
                composition: composition
            )
        }
        #expect(throws: (any Error).self) {
            try ConfigCommandLogic.setBackendSecret(
                ascendantID: id.uuidString,
                key: "env",
                value: "secret-must-not-be-accepted-here",
                store: store,
                composition: composition
            )
        }

        var output: [String] = []
        try ConfigCommandLogic.listBackendKeys(
            ascendantID: id.uuidString,
            store: store,
            composition: composition,
            writeOutput: { output.append($0) }
        )
        let text = output.joined(separator: "\n")
        #expect(text.contains("kind: acp-client"))
        #expect(text.contains("command"))
        #expect(text.contains("args"))
        #expect(text.contains("env"))
        #expect(try store.loadManifest().ascendants.last?.backend.settings["commnad"] == nil)
        #expect(try store.loadManifest().ascendants.last?.backend.secrets.isEmpty == true)
    }

    @Test("a configured ACP Ascendant starts beside a Positronic Ascendant")
    @MainActor
    func startsMixedNodeWithACPBackend() async throws {
        let positronicID = UUID()
        let acpID = UUID()
        let positronicTimelineID = UUID()
        let acpTimelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-mixed-\(UUID().uuidString)"),
            node: .init(id: UUID()),
            ascendants: [
                .init(id: positronicID, name: "Positronic", defaultTimelineID: positronicTimelineID),
                .init(
                    id: acpID,
                    name: "ACP agent",
                    defaultTimelineID: acpTimelineID,
                    backend: .init(kind: "acp-client", settings: ["command": .string("fixture-agent")])
                ),
            ],
            timelines: [
                .init(id: positronicTimelineID, title: "Positronic", operatingAscendantID: positronicID),
                .init(id: acpTimelineID, title: "ACP", operatingAscendantID: acpID),
            ]
        )
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: BackendComposition.default.makeAdapters()
        )

        try await runtime.start()
        let snapshot = await runtime.snapshot()
        #expect(Set(snapshot.ascendantIDs) == [positronicID, acpID])
        #expect(Set(snapshot.operatedTimelineIDs) == [positronicTimelineID, acpTimelineID])
        await runtime.shutdown()
    }

    @Test("an unregistered backend kind still fails during serve assembly")
    @MainActor
    func unregisteredKindFailsAssembly() async throws {
        let ascendantID = UUID()
        let timelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-unknown-\(UUID().uuidString)"),
            node: .init(id: UUID()),
            ascendants: [
                .init(
                    id: ascendantID,
                    name: "Unknown",
                    defaultTimelineID: timelineID,
                    backend: .init(kind: "not-registered")
                ),
            ],
            timelines: [.init(id: timelineID, title: "Unknown", operatingAscendantID: ascendantID)]
        )

        do {
            _ = try await NodeRuntime(
                plan: manifest.compileLaunchPlan(),
                adapters: BackendComposition.default.makeAdapters()
            )
            Issue.record("An unregistered backend kind unexpectedly assembled.")
        } catch let error as NodeRuntimeError {
            guard case .unsupportedAscendantKind("not-registered") = error else {
                Issue.record("Unexpected NodeRuntimeError: \(error)")
                return
            }
        }
    }
}
