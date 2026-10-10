// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticHost
import Testing

@testable import GnosticCLI

@Suite("Configuration console")
struct ConfigConsoleCommandTests {
    private func seeded() throws -> (TemporaryFolder, CLIConfigurationStore, UUID) {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        let id = try store.loadManifest().ascendants[0].id
        return (folder, store, id)
    }

    private let registry = ModuleRegistry(schemaVersion: 1, modules: [
        ModuleRegistryEntry(
            id: "GNO-MOD-RLM",
            name: "RLM",
            targets: [],
            status: "incubating",
            owningIssue: "https://github.com/phynics/Gnostic/issues/1",
            runnable: true,
            reviewBy: "2026-12-01"
        ),
        ModuleRegistryEntry(
            id: "GNO-MOD-PARKED",
            name: "Parked",
            status: "parked",
            owningIssue: "https://github.com/phynics/Gnostic/issues/2",
            reviewBy: "2026-12-01"
        ),
    ])

    @Test("config registers the module and regime console commands")
    func commandsAreRegistered() {
        let config = ConfigCommand.helpMessage()
        #expect(config.contains("module"))
        #expect(config.contains("regime"))

        let module = ConfigModuleCommand.helpMessage()
        for sub in ["list", "enable", "disable", "keys"] {
            #expect(module.contains(sub), "missing config module subcommand: \(sub)")
        }
    }

    @Test("config module list reports registry status and a cautionary warning")
    func moduleListReportsStatus() {
        let entries = ConfigConsoleLogic.modules(registry: registry)
        let rlm = entries.first { $0.name == "rlm" }
        #expect(rlm?.status == "incubating")
        #expect(rlm?.requiresModelService == true)
        #expect(rlm?.warning?.contains("incubating") == true)
        #expect(rlm?.keys.map(\.name) == ["rlm.worker"])
    }

    @Test("enabling a module writes the extensions array and warns")
    func enableModuleWritesSelection() throws {
        let (_, store, id) = try seeded()
        let mutation = try ConfigConsoleLogic.enableModule(
            ascendantID: id.uuidString, module: "rlm", store: store, registry: registry
        )
        #expect(mutation.enabled)
        #expect(mutation.warnings.count == 1)

        let backend = try store.loadManifest().ascendants[0].backend
        #expect(ConfigConsoleLogic.selectedNames(in: backend) == ["rlm"])

        _ = try ConfigConsoleLogic.disableModule(ascendantID: id.uuidString, module: "rlm", store: store)
        let cleared = try store.loadManifest().ascendants[0].backend
        #expect(ConfigConsoleLogic.selectedNames(in: cleared).isEmpty)
    }

    @Test("an unknown module is rejected with the known list")
    func unknownModuleRejected() throws {
        let (_, store, id) = try seeded()
        #expect(throws: (any Error).self) {
            _ = try ConfigConsoleLogic.enableModule(
                ascendantID: id.uuidString, module: "nope", store: store
            )
        }
    }

    @Test("module keys lists the selected module's namespaced keys")
    func moduleKeysListSelection() throws {
        let (_, store, id) = try seeded()
        _ = try ConfigConsoleLogic.enableModule(ascendantID: id.uuidString, module: "rlm", store: store)
        let entries = try ConfigConsoleLogic.moduleKeys(ascendantID: id.uuidString, store: store)
        #expect(entries.map(\.name) == ["rlm"])
        #expect(entries.first?.keys.map(\.name) == ["rlm.worker"])
    }

    @Test("the Regime resolver names the modules serve composes and the configured provider")
    func regimeMatchesComposition() throws {
        let (_, store, id) = try seeded()
        _ = try ConfigConsoleLogic.enableModule(ascendantID: id.uuidString, module: "rlm", store: store)
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "provider", value: "openai", store: store
        )
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "model", value: "gpt-5", store: store
        )

        let manifest = try store.loadManifest()
        let ascendant = try #require(manifest.ascendants.first)
        let regime = try RegimeResolver.resolve(ascendantID: id, manifest: manifest)
        #expect(regime.modules == (try BackendComposition.default.selectedModuleNames(for: ascendant)))
        #expect(regime.modules == ["rlm"])
        #expect(regime.backendKind == "positronic")
        #expect(regime.provider == "openai")
        #expect(regime.modelTiers["primary"] == "gpt-5")
        #expect(regime.policies["approvalMode"] == "auto")
    }

    @Test("validation reports a missing manifest with a remediation hint")
    func validationReportsMissingManifest() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        let report = ConfigConsoleLogic.validationReport(store: store)
        #expect(!report.valid)
        #expect(report.issues.first?.reasonCode == "missingFile")
        #expect(report.issues.first?.hint.contains("config init") == true)
        #expect(report.path.hasSuffix("config.json"))
    }

    @Test("validation reports a malformed manifest with a path")
    func validationReportsMalformedManifest() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: file)
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        let report = ConfigConsoleLogic.validationReport(store: store)
        #expect(!report.valid)
        #expect(report.issues.first?.reasonCode == "malformedFile")
    }

    @Test("a dry run renders a diff and leaves the manifest unchanged")
    func dryRunDoesNotWrite() throws {
        let (_, store, id) = try seeded()
        let before = try store.loadManifest()
        var diff = ""
        try ConfigConsoleLogic.applyMutation(store: store, dryRun: true, apply: { preview in
            try ConfigCommandLogic.setBackendValue(
                ascendantID: id.uuidString, key: "provider", value: "openai", store: preview
            )
        }, writeOutput: { diff = $0 })
        let after = try store.loadManifest()
        #expect(before == after)
        #expect(diff.contains("+ "))
        #expect(diff.contains("openai"))
    }

    @Test("a dry run of a secret write never prints the secret")
    func dryRunRedactsSecrets() throws {
        let (_, store, id) = try seeded()
        var diff = ""
        try ConfigConsoleLogic.applyMutation(store: store, dryRun: true, apply: { preview in
            try ConfigCommandLogic.setBackendSecret(
                ascendantID: id.uuidString, key: "apiKey", value: "sk-super-secret", store: preview
            )
        }, writeOutput: { diff = $0 })
        #expect(!diff.contains("sk-super-secret"))
        #expect(try store.loadManifest().ascendants[0].backend.secrets["apiKey"] == nil)
    }

    @Test("output format accepts only human and json")
    func outputFormatValidation() throws {
        #expect(try OutputFormat.parse("JSON") == .json)
        #expect(try OutputFormat.parse("human") == .human)
        #expect(throws: (any Error).self) { _ = try OutputFormat.parse("yaml") }
    }
}
