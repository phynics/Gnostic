// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

@Suite("Doctor Runtime configuration")
struct DoctorRuntimeConfigurationTests {
    @Test("missing ACP command and malformed args have actionable schema findings")
    func invalidACPCommandSettingsAreReported() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })

        let missingCommand = DoctorLogic.run(store: store, composition: .default)
        let commandFinding = try #require(missingCommand.findings.first { $0.path?.hasSuffix(".settings.command") == true })
        #expect(commandFinding.severity == .error)
        #expect(commandFinding.hint?.contains("config backend set") == true)

        try store.mutateManifest { manifest in
            manifest.ascendants[0].backend.settings["command"] = .string("/path/to/runtime")
            manifest.ascendants[0].backend.settings["args"] = .string("not-json")
        }
        let malformedArgs = DoctorLogic.run(store: store, composition: .default)
        let argsFinding = try #require(malformedArgs.findings.first { $0.path?.hasSuffix(".settings.args") == true })
        #expect(argsFinding.severity == .error)
        #expect(argsFinding.hint?.contains("JSON") == true)
    }

    @Test("ACP command configuration does not require host provider or model settings")
    func acpRuntimeDoesNotRequireHostModelSettings() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store, writeOutput: { _ in })
        let ascendantID = try store.loadManifest().ascendants[0].id
        try store.mutateManifest { manifest in
            manifest.ascendants[0].backend.settings["command"] = .string("/bin/sleep")
            manifest.ascendants[0].backend.settings["args"] = .string("[\"3600\"]")
            manifest.ascendants[0].backend.settings["extensions"] = .array([.string("rlm")])
        }

        let report = DoctorLogic.run(store: store, composition: .default)

        #expect(report.healthy)
        #expect(!report.findings.contains { $0.check == "provider" })
        #expect(!report.findings.contains { $0.check == "modelTier" })
        #expect(report.findings.contains { $0.check == "backend" && $0.severity == .ok })
        #expect(try store.loadManifest().ascendants[0].id == ascendantID)
    }
}
