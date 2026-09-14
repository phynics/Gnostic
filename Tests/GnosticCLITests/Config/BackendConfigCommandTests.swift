// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

@Suite("Generic backend configuration commands")
struct BackendConfigCommandTests {
    private func seeded() throws -> (TemporaryFolder, CLIConfigurationStore, UUID) {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        let id = try store.loadManifest().ascendants[0].id
        return (folder, store, id)
    }

    @Test("config exposes a generic backend command group")
    func backendCommandIsRegistered() {
        let help = ConfigCommand.helpMessage()
        #expect(help.contains("backend"))

        let backend = ConfigCommand.Backend.helpMessage()
        for sub in ["set", "set-secret", "clear", "keys"] {
            #expect(backend.contains(sub), "missing config backend subcommand: \(sub)")
        }
    }

    @Test("a setting is written to settings and a secret to secrets")
    func setWritesToTheCorrectDictionary() throws {
        let (_, store, id) = try seeded()

        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "model", value: "gpt-5", store: store
        )
        try ConfigCommandLogic.setBackendSecret(
            ascendantID: id.uuidString, key: "apiKey", value: "sk-test", store: store
        )

        let backend = try store.loadManifest().ascendants[0].backend
        #expect(backend.settings["model"]?.stringValue == "gpt-5")
        #expect(backend.secrets["apiKey"]?.stringValue == "sk-test")
        #expect(backend.settings["apiKey"] == nil)
    }

    @Test("an unadvertised key is rejected at write time")
    func unknownKeyIsRejected() throws {
        let (_, store, id) = try seeded()

        #expect(throws: (any Error).self) {
            try ConfigCommandLogic.setBackendValue(
                ascendantID: id.uuidString, key: "modle", value: "gpt-5", store: store
            )
        }
        #expect(try store.loadManifest().ascendants[0].backend.settings["modle"] == nil)
    }

    @Test("a secret key cannot be written as a plain setting")
    func secretKeyRejectedAsSetting() throws {
        let (_, store, id) = try seeded()

        #expect(throws: (any Error).self) {
            try ConfigCommandLogic.setBackendValue(
                ascendantID: id.uuidString, key: "apiKey", value: "sk-leak", store: store
            )
        }
        #expect(try store.loadManifest().ascendants[0].backend.settings["apiKey"] == nil)
    }

    @Test("advertised keys are listable for any registered kind")
    func keysAreListable() throws {
        let (_, store, id) = try seeded()
        var output: [String] = []

        try ConfigCommandLogic.listBackendKeys(
            ascendantID: id.uuidString, store: store, writeOutput: { output.append($0) }
        )

        let text = output.joined(separator: "\n")
        #expect(text.contains("provider"))
        #expect(text.contains("apiKey"))
        #expect(text.contains("secret"))
        // Summaries come from the backend, not from a CLI-side copy.
        #expect(text.contains("Primary model name."))
    }

    @Test("config show redacts by storage location, not by field name")
    func redactionIsStructural() throws {
        let (_, store, id) = try seeded()

        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "model", value: "gpt-5", store: store
        )
        try ConfigCommandLogic.setBackendSecret(
            ascendantID: id.uuidString, key: "apiKey", value: "sk-should-not-appear", store: store
        )

        var output: [String] = []
        try ConfigCommandLogic.show(store: store, writeOutput: { output.append($0) })
        let text = output.joined(separator: "\n")

        #expect(!text.contains("sk-should-not-appear"))
        #expect(text.contains("<redacted>"))
        #expect(text.contains("gpt-5"))
    }

    @Test("an ascendant can be created with a registered non-default kind")
    func ascendantKindIsSelectable() throws {
        let (_, store, _) = try seeded()

        try ConfigCommandLogic.addAscendant(
            name: "Fixture", description: "", kind: "positronic", store: store
        )
        let manifest = try store.loadManifest()
        #expect(manifest.ascendants.last?.backend.kind == "positronic")

        #expect(throws: (any Error).self) {
            try ConfigCommandLogic.addAscendant(
                name: "Unknown", description: "", kind: "not-registered", store: store
            )
        }
    }

    @Test("the deprecated Positronic command group still works")
    @available(*, deprecated, message: "Exercises the deprecated kind-specific seam on purpose.")
    func deprecatedPositronicStillWorks() throws {
        let (_, store, id) = try seeded()

        try ConfigCommandLogic.configurePositronic(
            ascendantID: id.uuidString, provider: "openai", endpoint: nil,
            model: "gpt-5", utilityModel: nil, fastModel: nil, store: store
        )
        let backend = try store.loadManifest().ascendants[0].backend
        #expect(backend.settings["provider"]?.stringValue == "openai")
        #expect(backend.settings["model"]?.stringValue == "gpt-5")
        #expect(ConfigCommand.Positronic.configuration.abstract.lowercased().contains("deprecated"))
    }
}
