// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

@Suite("CLI configuration")
struct CLIConfigurationTests {
    private func store(folder: TemporaryFolder, environment: [String: String] = [:]) -> CLIConfigurationStore {
        CLIConfigurationStore(
            baseDirectory: folder.url,
            environment: environment
        )
    }

    @Test("an empty store reports defaults")
    func emptyStoreReportsDefaults() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)

        let config = try store.load()

        #expect(config.mqttHost == "127.0.0.1")
        #expect(config.mqttPort == 1883)
        #expect(config.mqttNamespace == "gnostic")
        #expect(config.mqttUsername == nil)
        #expect(config.mqttPassword == nil)
        #expect(config.llmProvider == nil)
        #expect(config.llmAPIKey == nil)
    }

    @Test("set then show round-trips every non-secret key")
    func setThenShowRoundTripsNonSecretKeys() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)

        try store.setValue("mqtt.example.com", for: .mqttHost)
        try store.setValue("1884", for: .mqttPort)
        try store.setValue("my-namespace", for: .mqttNamespace)
        try store.setValue("alice", for: .mqttUsername)
        try store.setValue("anthropic", for: .llmProvider)
        try store.setValue("https://api.anthropic.com", for: .llmEndpoint)
        try store.setValue("claude-sonnet", for: .llmModel)
        try store.setValue("claude-haiku", for: .llmUtilityModel)
        try store.setValue("claude-haiku", for: .llmFastModel)

        let config = try store.load()

        #expect(config.mqttHost == "mqtt.example.com")
        #expect(config.mqttPort == 1884)
        #expect(config.mqttNamespace == "my-namespace")
        #expect(config.mqttUsername == "alice")
        #expect(config.llmProvider == "anthropic")
        #expect(config.llmEndpoint == "https://api.anthropic.com")
        #expect(config.llmModel == "claude-sonnet")
        #expect(config.llmUtilityModel == "claude-haiku")
        #expect(config.llmFastModel == "claude-haiku")
    }

    @Test("secrets are stored with restrictive permissions and redacted on show")
    func secretsAreStoredPrivateAndRedacted() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)

        try store.setValue("s3cr3t", for: .mqttPassword)
        try store.setValue("sk-ant-123", for: .llmAPIKey)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.path().path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600, "secret config file must be 0600, was \(String(describing: permissions))")

        let shown = store.redactedDescription(for: try store.load())
        #expect(!shown.contains("s3cr3t"))
        #expect(!shown.contains("sk-ant-123"))
        #expect(shown.contains("mqtt.password"))
        #expect(shown.contains("<redacted>"))
    }

    @Test("environment overrides file values")
    func environmentOverridesFile() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)
        try store.setValue("file.example.com", for: .mqttHost)

        let effective = try CLIConfigurationStore(
            baseDirectory: folder.url,
            environment: ["GNOSTIC_MQTT_HOST": "env.example.com"]
        ).load()

        #expect(effective.mqttHost == "env.example.com")
    }

    @Test("malformed json and invalid ports produce structured errors naming the key")
    func malformedInputProducesStructuredErrors() throws {
        let folder = try TemporaryFolder()
        FileManager.default.createFile(
            atPath: folder.url.appendingPathComponent("config.json").path,
            contents: Data("{not json".utf8)
        )
        let store = self.store(folder: folder)

        #expect(throws: CLIConfigurationError.self) {
            try store.load()
        }

        let invalidPort = self.store(folder: folder)
        #expect(throws: CLIConfigurationError.self) {
            try invalidPort.setValue("99999", for: .mqttPort)
        }
    }

    @Test("config path resolves under the base directory")
    func configPathResolves() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)
        #expect(store.path().path.hasSuffix("config.json"))
        #expect(store.path().deletingLastPathComponent().path == folder.url.path)
    }

    @Test("GNOSTIC_CONFIG points the store at a custom directory or file")
    func gnosticConfigEnvironmentOverridesLocation() throws {
        let folder = try TemporaryFolder()
        let dirStore = CLIConfigurationStore(
            environment: ["GNOSTIC_CONFIG": folder.url.path]
        )
        #expect(dirStore.path().deletingLastPathComponent().path == folder.url.path)

        let fileURL = folder.url.appendingPathComponent("custom.json")
        let fileStore = CLIConfigurationStore(
            environment: ["GNOSTIC_CONFIG": fileURL.path]
        )
        #expect(fileStore.path().path == fileURL.path)
    }

    @Test("subcommand help is available and names the config keys")
    func subcommandHelp() {
        let showHelp = ConfigCommand.Show.helpMessage()
        #expect(showHelp.contains("Print the effective configuration with secrets redacted"))
        #expect(showHelp.contains("show"))

        let setHelp = ConfigCommand.Set.helpMessage()
        #expect(setHelp.contains("Set a configuration key to a value"))
        #expect(setHelp.contains("Dotted configuration key"))

        let pathHelp = ConfigCommand.Path.helpMessage()
        #expect(pathHelp.contains("Print the config file path"))
        #expect(pathHelp.contains("path"))
    }

    @Test("CLI config maps onto Axoloty MQTT options and PK LLM configuration")
    func mapsOntoDownstreamTypes() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)
        try store.setValue("broker.example.com", for: .mqttHost)
        try store.setValue("1884", for: .mqttPort)
        try store.setValue("alice", for: .mqttUsername)
        try store.setValue("anthropic", for: .llmProvider)
        try store.setValue("https://api.anthropic.com", for: .llmEndpoint)
        try store.setValue("claude-sonnet", for: .llmModel)

        let config = try store.load()

        let mqtt = config.mqttClientOptions()
        #expect(mqtt.host == "broker.example.com")
        #expect(mqtt.port == 1884)
        #expect(mqtt.username == "alice")

        let llm = try #require(config.llmConfiguration())
        #expect(llm.activeProvider == .anthropic)
        #expect(llm.activeProviderConfiguration.endpoint == "https://api.anthropic.com")
        #expect(llm.activeProviderConfiguration.modelName == "claude-sonnet")
    }

    @Test("unset or unknown LLM provider yields nil configuration")
    func unknownProviderYieldsNil() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)

        let unset = try store.load()
        #expect(unset.llmConfiguration() == nil)

        try store.setValue("nonexistent", for: .llmProvider)
        let unknown = try store.load()
        #expect(unknown.llmConfiguration() == nil)
    }

    @Test("CLI config against a custom config file via environment")
    func customConfigFileViaEnvironment() throws {
        let folder = try TemporaryFolder()
        let fileURL = folder.url.appendingPathComponent("custom.json")
        let store = CLIConfigurationStore(environment: ["GNOSTIC_CONFIG": fileURL.path])
        try store.setValue("custom.example.com", for: .mqttHost)

        let reloaded = CLIConfigurationStore(environment: ["GNOSTIC_CONFIG": fileURL.path])
        #expect(try reloaded.load().mqttHost == "custom.example.com")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

/// A throwaway directory for isolated config tests.
struct TemporaryFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}