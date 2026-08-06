// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The effective configuration for the `gnostic` CLI.
///
/// Values are read from the user-level config file and overridden by
/// environment variables. Secrets remain distinct so commands can redact them.
public struct CLIConfiguration: Sendable, Equatable, Codable {
    /// MQTT broker host.
    public var mqttHost: String
    /// MQTT broker port.
    public var mqttPort: Int
    /// MQTT namespace (topic prefix).
    public var mqttNamespace: String
    /// Optional MQTT username.
    public var mqttUsername: String?
    /// Optional MQTT password (secret).
    public var mqttPassword: String?
    /// LLM provider name, when configured.
    public var llmProvider: String?
    /// LLM endpoint URL, when configured.
    public var llmEndpoint: String?
    /// Primary LLM model name, when configured.
    public var llmModel: String?
    /// Utility LLM model name, when configured.
    public var llmUtilityModel: String?
    /// Fast LLM model name, when configured.
    public var llmFastModel: String?
    /// LLM API key (secret).
    public var llmAPIKey: String?

    /// The bundled defaults used when no file or environment supplies a value.
    public static let defaults = CLIConfiguration(
        mqttHost: "127.0.0.1",
        mqttPort: 1883,
        mqttNamespace: "gnostic",
        mqttUsername: nil,
        mqttPassword: nil,
        llmProvider: nil,
        llmEndpoint: nil,
        llmModel: nil,
        llmUtilityModel: nil,
        llmFastModel: nil,
        llmAPIKey: nil
    )

    /// Reads the current value for a key.
    ///
    /// - Parameter key: The configuration key.
    /// - Returns: The current value, or `nil` when unset.
    public func value(for key: ConfigurationKey) -> String? {
        switch key {
        case .mqttHost: mqttHost
        case .mqttPort: String(mqttPort)
        case .mqttNamespace: mqttNamespace
        case .mqttUsername: mqttUsername
        case .mqttPassword: mqttPassword
        case .llmProvider: llmProvider
        case .llmEndpoint: llmEndpoint
        case .llmModel: llmModel
        case .llmUtilityModel: llmUtilityModel
        case .llmFastModel: llmFastModel
        case .llmAPIKey: llmAPIKey
        }
    }

    /// Produces a copy with the given key set to a validated value.
    ///
    /// - Parameters:
    ///   - key: The key to set.
    ///   - value: The raw string value.
    /// - Returns: A copy with the updated value.
    /// - Throws: `CLIConfigurationError.invalidValue`.
    public func setting(_ value: String, for key: ConfigurationKey) throws -> CLIConfiguration {
        let validated = try key.validatedValue(value)
        var copy = self
        switch key {
        case .mqttHost: copy.mqttHost = validated
        case .mqttPort: copy.mqttPort = Int(validated) ?? copy.mqttPort
        case .mqttNamespace: copy.mqttNamespace = validated
        case .mqttUsername: copy.mqttUsername = validated
        case .mqttPassword: copy.mqttPassword = validated
        case .llmProvider: copy.llmProvider = validated
        case .llmEndpoint: copy.llmEndpoint = validated
        case .llmModel: copy.llmModel = validated
        case .llmUtilityModel: copy.llmUtilityModel = validated
        case .llmFastModel: copy.llmFastModel = validated
        case .llmAPIKey: copy.llmAPIKey = validated
        }
        return copy
    }

    /// A human-readable rendering with secret values replaced by markers.
    ///
    /// - Parameter configuration: The configuration to render.
    /// - Returns: A redacted multi-line description.
    public func redactedDescription() -> String {
        var lines: [String] = []
        for key in ConfigurationKey.allCases {
            guard let value = value(for: key) else { continue }
            let shown = key.isSecret ? "<redacted>" : value
            lines.append("\(key.rawValue) = \(shown)")
        }
        return lines.isEmpty ? "(no configuration set)" : lines.joined(separator: "\n")
    }
}

/// The on-disk representation for the config file.
///
/// Uses dotted keys so `config set mqtt.host` maps directly onto JSON.
private struct PersistedConfiguration: Codable {
    var mqttHost: String?
    var mqttPort: Int?
    var mqttNamespace: String?
    var mqttUsername: String?
    var mqttPassword: String?
    var llmProvider: String?
    var llmEndpoint: String?
    var llmModel: String?
    var llmUtilityModel: String?
    var llmFastModel: String?
    var llmAPIKey: String?

    enum CodingKeys: String, CodingKey {
        case mqttHost = "mqtt.host"
        case mqttPort = "mqtt.port"
        case mqttNamespace = "mqtt.namespace"
        case mqttUsername = "mqtt.username"
        case mqttPassword = "mqtt.password"
        case llmProvider = "llm.provider"
        case llmEndpoint = "llm.endpoint"
        case llmModel = "llm.model"
        case llmUtilityModel = "llm.utilityModel"
        case llmFastModel = "llm.fastModel"
        case llmAPIKey = "llm.apiKey"
    }

    init() {}

    init(_ configuration: CLIConfiguration) {
        mqttHost = configuration.mqttHost
        mqttPort = configuration.mqttPort
        mqttNamespace = configuration.mqttNamespace
        mqttUsername = configuration.mqttUsername
        mqttPassword = configuration.mqttPassword
        llmProvider = configuration.llmProvider
        llmEndpoint = configuration.llmEndpoint
        llmModel = configuration.llmModel
        llmUtilityModel = configuration.llmUtilityModel
        llmFastModel = configuration.llmFastModel
        llmAPIKey = configuration.llmAPIKey
    }

    func applying(_ configuration: CLIConfiguration) -> CLIConfiguration {
        var result = configuration
        if let mqttHost { result.mqttHost = mqttHost }
        if let mqttPort { result.mqttPort = mqttPort }
        if let mqttNamespace { result.mqttNamespace = mqttNamespace }
        if let mqttUsername { result.mqttUsername = mqttUsername }
        if let mqttPassword { result.mqttPassword = mqttPassword }
        if let llmProvider { result.llmProvider = llmProvider }
        if let llmEndpoint { result.llmEndpoint = llmEndpoint }
        if let llmModel { result.llmModel = llmModel }
        if let llmUtilityModel { result.llmUtilityModel = llmUtilityModel }
        if let llmFastModel { result.llmFastModel = llmFastModel }
        if let llmAPIKey { result.llmAPIKey = llmAPIKey }
        return result
    }
}

/// An actor-safe configuration store for the `gnostic` CLI.
///
/// The store reads and writes a user-level JSON file under a base directory
/// (default `~/.gnostic/config.json`), applies environment overrides, writes
/// secret values with `0600` permissions, and redacts secrets in output.
public struct CLIConfigurationStore: Sendable {
    /// The default config file name inside the base directory.
    static let defaultFileName = "config.json"

    /// The directory holding the default config file (unused when an explicit
    /// config file path is supplied).
    public let baseDirectory: URL
    /// An explicit config file path supplied via `GNOSTIC_CONFIG`, when one
    /// exists and points at a file rather than a directory.
    private let explicitConfigURL: URL?
    /// Environment overrides keyed by variable name.
    public let environment: [String: String]

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - baseDirectory: The directory that holds `config.json`. When nil, the
    ///     `GNOSTIC_CONFIG` environment variable (a file or directory path)
    ///     is honored; otherwise `~/.gnostic` is used.
    ///   - environment: Environment variables for override precedence.
    public init(
        baseDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
            self.explicitConfigURL = nil
        } else if let custom = environment["GNOSTIC_CONFIG"], !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if url.pathExtension == "json" || !url.hasDirectoryPath {
                // Treat a non-directory path as the config file itself.
                self.baseDirectory = url.deletingLastPathComponent()
                self.explicitConfigURL = url
            } else {
                self.baseDirectory = url
                self.explicitConfigURL = nil
            }
        } else {
            self.baseDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gnostic", isDirectory: true)
            self.explicitConfigURL = nil
        }
        self.environment = environment
    }

    /// The config file location.
    public func path() -> URL {
        explicitConfigURL ?? baseDirectory.appendingPathComponent(Self.defaultFileName)
    }

    /// Loads the effective configuration: file values overlaid with
    /// environment overrides, falling back to defaults.
    ///
    /// - Throws: `CLIConfigurationError.malformedFile` when the file cannot be
    ///   decoded.
    public func load() throws -> CLIConfiguration {
        var configuration = CLIConfiguration.defaults
        let url = path()

        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if data.isEmpty {
                // An empty file (e.g. freshly created) counts as no values.
            } else {
                let persisted: PersistedConfiguration
                do {
                    persisted = try JSONDecoder().decode(PersistedConfiguration.self, from: data)
                } catch {
                    throw CLIConfigurationError.malformedFile(url)
                }
                configuration = persisted.applying(configuration)
            }
        }

        for key in ConfigurationKey.allCases {
            guard let variable = key.environmentVariable,
                  let value = environment[variable] else { continue }
            configuration = try configuration.setting(value, for: key)
        }

        return configuration
    }

    /// Sets a key in the config file (after applying environment overrides for
    /// the invariant that the file only stores what was explicitly set).
    ///
    /// - Parameters:
    ///   - value: The raw string value to store.
    ///   - key: The key to set.
    /// - Throws: `CLIConfigurationError.invalidValue` or `.writeFailed`.
    public func setValue(_ value: String, for key: ConfigurationKey) throws {
        // Validate and type-normalize before persisting.
        let validated = try key.validatedValue(value)
        let current = try load().setting(validated, for: key)

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let persisted = PersistedConfiguration(current)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persisted)

        do {
            try data.write(to: path(), options: .atomic)
        } catch {
            throw CLIConfigurationError.writeFailed(path())
        }

        if key.isSecret {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path().path
            )
        }
    }

    /// A redacted description of the effective configuration.
    ///
    /// - Parameter configuration: The configuration to render.
    /// - Returns: A redacted multi-line description.
    public func redactedDescription(for configuration: CLIConfiguration) -> String {
        configuration.redactedDescription()
    }
}