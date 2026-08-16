// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The legacy flat representation accepted only during one-time migration.
struct PersistedConfiguration: Codable {
    static let acceptedKeys: Set<String> = [
        "mqtt.host", "mqtt.port", "mqtt.namespace", "mqtt.username", "mqtt.password",
        "llm.provider", "llm.endpoint", "llm.model", "llm.utilityModel", "llm.fastModel", "llm.apiKey",
    ]

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
