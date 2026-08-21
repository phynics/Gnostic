// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import Testing

@testable import GnosticCLI

@Suite("CLI command glue")
struct CommandGlueTests {
    @Test("legacy bridge command is no longer registered")
    func bridgeCommandIsRemoved() {
        #expect(GnosticCLI.configuration.version == "0.2.0")
        #expect(throws: (any Error).self) {
            _ = try GnosticCLI.parseAsRoot(["bridge"])
        }
    }

    @Test("turn is no longer a root command")
    func turnCommandIsRemoved() {
        let help = GnosticCLI.helpMessage().lowercased()
        #expect(help.contains("acp"))
        #expect(!help.contains("turn"))
        #expect(throws: (any Error).self) {
            _ = try GnosticCLI.parseAsRoot(["turn"])
        }
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-glue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("config show renders redacted output through the injected store")
    func configShowRendersRedacted() throws {
        let folder = try tempFolder()
        let store = CLIConfigurationStore(baseDirectory: folder, environment: [:])
        try store.setValue("broker.example.com", for: .mqttHost)
        try store.setValue("s3cr3t", for: .mqttPassword)

        var output: [String] = []
        try ConfigCommandLogic.show(store: store, writeOutput: { output.append($0) })

        let text = output.joined(separator: "\n")
        #expect(text.contains("mqtt.host = broker.example.com"))
        #expect(!text.contains("s3cr3t"))
        #expect(text.contains("<redacted>"))
    }

    @Test("broker set persists resource fields")
    func configSetPersists() throws {
        let folder = try tempFolder()
        let store = CLIConfigurationStore(baseDirectory: folder, environment: [:])

        try ConfigCommandLogic.setBroker(host: nil, port: nil, namespace: "test-ns", username: nil, store: store)

        #expect(try store.load().mqttNamespace == "test-ns")
    }

    @Test("config path prints the store location")
    func configPathPrints() throws {
        let folder = try tempFolder()
        let store = CLIConfigurationStore(baseDirectory: folder, environment: [:])

        var output: [String] = []
        try ConfigCommandLogic.path(store: store, writeOutput: { output.append($0) })

        #expect(output.first?.hasSuffix("config.json") == true)
    }
}
