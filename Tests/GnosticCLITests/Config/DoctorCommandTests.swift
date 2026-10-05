// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticHost
import Testing

@testable import GnosticCLI

/// A deterministic environment probe for doctor tests.
private struct StubProbe: DoctorProbing {
    var existingPaths: Set<String> = []
    var reachable: Set<String> = []

    func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }

    func tcpReachable(host: String, port: Int, timeout: Double) -> Bool {
        reachable.contains("\(host):\(port)")
    }
}

@Suite("Doctor diagnostics")
struct DoctorCommandTests {
    private func seeded() throws -> (TemporaryFolder, CLIConfigurationStore, UUID) {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        let id = try store.loadManifest().ascendants[0].id
        return (folder, store, id)
    }

    private var compositionWithFakeModule: BackendComposition {
        var composition = BackendComposition()
        composition.registerModule(GnosticModule(
            name: "fake",
            registryID: "GNO-MOD-RLM",
            requiresModelService: true,
            prerequisites: { _ in
                [GnosticModulePrerequisite(
                    name: "fake-exec",
                    path: "/missing/fake-exec",
                    isAvailable: false,
                    hint: "Install fake-exec."
                )]
            }
        ))
        return composition
    }

    private let registry = ModuleRegistry(schemaVersion: 1, modules: [
        ModuleRegistryEntry(
            id: "GNO-MOD-RLM",
            name: "RLM",
            status: "incubating",
            owningIssue: "https://github.com/phynics/Gnostic/issues/1",
            runnable: true,
            reviewBy: "2026-12-01"
        )
    ])

    @Test("doctor registers a top-level command")
    func commandIsRegistered() {
        #expect(GnosticCLI.helpMessage().contains("doctor"))
    }

    @Test("a valid but unconfigured Ascendant reports offline errors")
    func unconfiguredAscendantIsUnhealthy() throws {
        let (_, store, id) = try seeded()
        let composition = compositionWithFakeModule
        _ = try ConfigConsoleLogic.enableModule(
            ascendantID: id.uuidString, module: "fake", store: store,
            composition: composition, registry: registry
        )

        let report = DoctorLogic.run(
            store: store,
            composition: composition,
            registry: registry,
            probe: StubProbe()
        )

        #expect(!report.healthy)
        #expect(report.count(.error) >= 4)
        let checks = Set(report.findings.filter { $0.severity == .error }.map(\.check))
        #expect(checks.contains("provider"))
        #expect(checks.contains("modelService"))
        #expect(checks.contains("secret"))
        #expect(checks.contains("executor"))
        let executor = report.findings.first { $0.check == "executor" }
        #expect(executor?.hint == "Install fake-exec.")
        #expect(executor?.path == "/missing/fake-exec")
    }

    @Test("a configured Ascendant with no modules is healthy offline")
    func configuredAscendantIsHealthy() throws {
        let (_, store, id) = try seeded()
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "provider", value: "openai", store: store
        )
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "model", value: "gpt-5", store: store
        )
        try ConfigCommandLogic.setBackendSecret(
            ascendantID: id.uuidString, key: "apiKey", value: "sk-test", store: store
        )

        let report = DoctorLogic.run(
            store: store,
            composition: BackendComposition(),
            registry: registry,
            probe: StubProbe()
        )
        #expect(report.healthy)
        #expect(report.count(.error) == 0)
        #expect(report.online == false)
    }

    @Test("a missing manifest is reported as an error with a hint")
    func missingManifestReported() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        let report = DoctorLogic.run(store: store, composition: BackendComposition(), probe: StubProbe())
        #expect(!report.healthy)
        #expect(report.findings.first?.check == "manifest")
        #expect(report.findings.first?.hint?.contains("config init") == true)
    }

    @Test("online checks report an unreachable broker and provider endpoint")
    func onlineChecksReportFailures() throws {
        let (_, store, id) = try seeded()
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "provider", value: "openai", store: store
        )
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "model", value: "gpt-5", store: store
        )
        try ConfigCommandLogic.setBackendValue(
            ascendantID: id.uuidString, key: "endpoint", value: "http://127.0.0.1:1", store: store
        )
        try ConfigCommandLogic.setBackendSecret(
            ascendantID: id.uuidString, key: "apiKey", value: "sk-test", store: store
        )

        let report = DoctorLogic.run(
            store: store,
            composition: BackendComposition(),
            registry: registry,
            options: DoctorOptions(online: true, checkProvider: true),
            probe: StubProbe()
        )
        #expect(report.online == true)
        #expect(!report.healthy)
        #expect(report.findings.contains { $0.check == "broker" && $0.severity == .error })
        #expect(report.findings.contains { $0.check == "provider" && $0.severity == .warning })
        #expect(report.findings.contains { $0.check == "protocolMajor" && $0.severity == .ok })
    }

    @Test("a compiled-out module selection is an error")
    func compiledOutModuleIsError() throws {
        let (_, store, _) = try seeded()
        try store.mutateManifest { manifest in
            manifest.ascendants[0].backend.settings["extensions"] = .array([.string("ghost")])
        }
        let report = DoctorLogic.run(
            store: store,
            composition: BackendComposition(),
            registry: registry,
            probe: StubProbe()
        )
        #expect(!report.healthy)
        #expect(report.findings.contains { $0.check == "module" && $0.severity == .error })
    }
}
