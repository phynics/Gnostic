// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

@Suite("CLI command glue")
struct CommandGlueTests {
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

    @Test("config set persists and reports the key")
    func configSetPersists() throws {
        let folder = try tempFolder()
        let store = CLIConfigurationStore(baseDirectory: folder, environment: [:])

        var output: [String] = []
        try ConfigCommandLogic.set(key: "mqtt.namespace", value: "test-ns", store: store, writeOutput: { output.append($0) })

        #expect(output == ["Set mqtt.namespace."])
        #expect(try store.load().mqttNamespace == "test-ns")
    }

    @Test("config set rejects an unknown key")
    func configSetRejectsUnknownKey() throws {
        let folder = try tempFolder()
        let store = CLIConfigurationStore(baseDirectory: folder, environment: [:])

        #expect(throws: CLIConfigurationError.unknownKey("bogus.key")) {
            try ConfigCommandLogic.set(key: "bogus.key", value: "x", store: store)
        }
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