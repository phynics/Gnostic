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

