// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A configuration key in the `gnostic` CLI's dotted-key store.
///
/// Keys cover MQTT broker connection details and LLM provider details.
/// Secrets are excluded from `redactedDescription` output and stored with
/// restrictive file permissions.
public enum ConfigurationKey: String, CaseIterable, Sendable {
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

    /// Whether the key stores a secret that must be redacted and written with
    /// restrictive permissions.
    public var isSecret: Bool {
        switch self {
        case .mqttPassword, .llmAPIKey: return true
        default: return false
        }
    }

    /// The environment variable that overrides this key, when one exists.
    public var environmentVariable: String? {
        switch self {
        case .mqttHost: "GNOSTIC_MQTT_HOST"
        case .mqttPort: "GNOSTIC_MQTT_PORT"
        case .mqttNamespace: "GNOSTIC_MQTT_NAMESPACE"
        case .mqttUsername: "GNOSTIC_MQTT_USERNAME"
        case .mqttPassword: "GNOSTIC_MQTT_PASSWORD"
        case .llmProvider: "GNOSTIC_LLM_PROVIDER"
        case .llmEndpoint: "GNOSTIC_LLM_ENDPOINT"
        case .llmModel: "GNOSTIC_LLM_MODEL"
        case .llmUtilityModel: "GNOSTIC_LLM_UTILITY_MODEL"
        case .llmFastModel: "GNOSTIC_LLM_FAST_MODEL"
        case .llmAPIKey: "GNOSTIC_LLM_API_KEY"
        }
    }

    /// Validates and converts a string value for this key.
    ///
    /// - Parameter value: The raw string value.
    /// - Returns: The validated value.
    /// - Throws: `CLIConfigurationError.invalidValue` when the value cannot be
    ///   represented for this key (for example an out-of-range port).
    public func validatedValue(_ value: String) throws -> String {
        switch self {
        case .mqttPort:
            guard let port = Int(value), (1...65535).contains(port) else {
                throw CLIConfigurationError.invalidValue(key: self, value: value)
            }
            return String(port)
        default:
            return value
        }
    }
}

/// Failures produced by the CLI configuration store.
public enum CLIConfigurationError: Error, Sendable, Equatable, LocalizedError {
    /// The configuration file exists but cannot be decoded.
    case malformedFile(URL)
    /// The selected manifest does not exist. `config init` is responsible for creating it.
    case missingFile(URL)
    /// A decoded manifest violates a schema invariant.
    case invalidManifest(NodeManifestError, URL)
    /// A value cannot be represented for the given key.
    case invalidValue(key: ConfigurationKey, value: String)
    /// An unknown dotted key was requested.
    case unknownKey(String)
    /// A secret was requested for a key that does not store secrets.
    case notASecret(ConfigurationKey)
    /// The selected file already exists and cannot be initialized again.
    case fileAlreadyExists(URL)
    /// A resource ID does not exist in the selected manifest.
    case resourceNotFound(kind: String, id: UUID)
    /// A resource cannot be removed because other resources still reference it.
    case resourceReferenced(kind: String, id: UUID, references: [String])
    /// A command argument is invalid independently of a dotted configuration key.
    case invalidArgument(String)
    /// The configuration file could not be written.
    case writeFailed(URL)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .malformedFile(url):
            return "The configuration file at \(url.path) is malformed."
        case let .missingFile(url):
            return "No configuration manifest exists at \(url.path); run `gnostic config init`."
        case let .invalidManifest(error, url):
            return "The configuration manifest at \(url.path) is invalid: \(error.localizedDescription)"
        case let .invalidValue(key, value):
            return "Invalid value '\(value)' for \(key.rawValue)."
        case let .unknownKey(key):
            return "Unknown configuration key '\(key)'."
        case let .notASecret(key):
            return "\(key.rawValue) is not a secret key."
        case let .fileAlreadyExists(url):
            return "A configuration manifest already exists at \(url.path); refusing to overwrite it."
        case let .resourceNotFound(kind, id):
            return "No \(kind) resource exists with ID \(id.uuidString.lowercased())."
        case let .resourceReferenced(kind, id, references):
            return "Cannot remove \(kind) \(id.uuidString.lowercased()); it is referenced by \(references.joined(separator: ", "))."
        case let .invalidArgument(message):
            return message
        case let .writeFailed(url):
            return "Could not write the configuration file at \(url.path)."
        }
    }

    /// A machine-readable reason label for diagnostics.
    public var reasonCode: String {
        switch self {
        case .malformedFile: "malformedFile"
        case .missingFile: "missingFile"
        case let .invalidManifest(error, _): error.reasonCode
        case .invalidValue: "invalidValue"
        case .unknownKey: "unknownKey"
        case .notASecret: "notASecret"
        case .fileAlreadyExists: "fileAlreadyExists"
        case .resourceNotFound: "resourceNotFound"
        case .resourceReferenced: "resourceReferenced"
        case .invalidArgument: "invalidArgument"
        case .writeFailed: "writeFailed"
        }
    }
}
