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

    @Test("generic compatibility keys cannot create an implicit Positronic target")
    func genericLLMSettingRequiresExplicitAscendantSelection() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)

        #expect(throws: CLIConfigurationError.self) {
            try store.setValue("anthropic", for: .llmProvider)
        }
        #expect(!FileManager.default.fileExists(atPath: store.path().path))
    }

    @Test("broker compatibility and selected Positronic settings round-trip")
    func setThenShowRoundTripsNonSecretKeys() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)

        try ConfigCommandLogic.initialize(store: store)
        let ascendantID = try #require(try store.loadManifest().ascendants.first?.id.uuidString)

        try store.setValue("mqtt.example.com", for: .mqttHost)
        try store.setValue("1884", for: .mqttPort)
        try store.setValue("my-namespace", for: .mqttNamespace)
        try store.setValue("alice", for: .mqttUsername)
        try ConfigCommandLogic.configurePositronic(
            ascendantID: ascendantID, provider: "anthropic", endpoint: "https://api.anthropic.com",
            model: "claude-sonnet", utilityModel: "claude-haiku", fastModel: "claude-haiku", store: store
        )

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

        try ConfigCommandLogic.initialize(store: store)
        let ascendantID = try #require(try store.loadManifest().ascendants.first?.id.uuidString)

        try store.setValue("s3cr3t", for: .mqttPassword)
        try ConfigCommandLogic.setPositronicAPIKey(id: ascendantID, value: "sk-ant-123", store: store)

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
        #expect(FileManager.default.createFile(
            atPath: folder.url.appendingPathComponent("config.json").path,
            contents: Data("{not json".utf8)
        ))
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

    @Test("GNOSTIC_CONFIG always names the selected manifest file")
    func gnosticConfigEnvironmentOverridesLocation() throws {
        let folder = try TemporaryFolder()
        let fileURL = folder.url.appendingPathComponent("custom.json")
        let fileStore = CLIConfigurationStore(
            environment: ["GNOSTIC_CONFIG": fileURL.path]
        )
        #expect(fileStore.path().path == fileURL.path)

        let extensionlessURL = folder.url.appendingPathComponent("node-manifest")
        let extensionlessStore = CLIConfigurationStore(
            environment: ["GNOSTIC_CONFIG": extensionlessURL.path]
        )
        #expect(extensionlessStore.path().path == extensionlessURL.path)
    }

    @Test("resource subcommand help is available")
    func subcommandHelp() {
        let showHelp = ConfigCommand.Show.helpMessage()
        #expect(showHelp.contains("Print the effective configuration with secrets redacted"))
        #expect(showHelp.contains("show"))

        #expect(ConfigCommand.Broker.helpMessage().contains("set-password"))
        #expect(ConfigCommand.Timeline.helpMessage().contains("attach-workspace"))

        let pathHelp = ConfigCommand.Path.helpMessage()
        #expect(pathHelp.contains("Print the config file path"))
        #expect(pathHelp.contains("path"))
    }

    @Test("CLI config maps onto Axoloty MQTT options and PK LLM configuration")
    func mapsOntoDownstreamTypes() throws {
        let folder = try TemporaryFolder()
        let store = self.store(folder: folder)

        try ConfigCommandLogic.initialize(store: store)
        let ascendantID = try #require(try store.loadManifest().ascendants.first?.id.uuidString)
        try store.setValue("broker.example.com", for: .mqttHost)
        try store.setValue("1884", for: .mqttPort)
        try store.setValue("alice", for: .mqttUsername)
        try ConfigCommandLogic.configurePositronic(
            ascendantID: ascendantID, provider: "anthropic", endpoint: "https://api.anthropic.com",
            model: "claude-sonnet", utilityModel: nil, fastModel: nil, store: store
        )

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

        try ConfigCommandLogic.initialize(store: store)
        let ascendantID = try #require(try store.loadManifest().ascendants.first?.id.uuidString)

        let unset = try store.load()
        #expect(unset.llmConfiguration() == nil)

        try ConfigCommandLogic.configurePositronic(
            ascendantID: ascendantID, provider: "nonexistent", endpoint: nil,
            model: nil, utilityModel: nil, fastModel: nil, store: store
        )
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
