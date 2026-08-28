// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts

extension CLIConfiguration {
    /// Maps the CLI's MQTT details onto Axoloty's connection options.
    ///
    /// No further string parsing is required downstream; host, port, username,
    /// and password are carried verbatim.
    ///
    /// - Returns: Axoloty MQTT client options.
    public func mqttClientOptions() -> MQTTClientOptions {
        let options = MQTTClientOptions(
            host: mqttHost,
            port: UInt16(clamping: mqttPort),
            shouldTryMDNSDiscovery: false,
            autoReconnect: false
        )
        options.username = mqttUsername
        options.password = mqttPassword
        return options
    }

    /// Maps the CLI's LLM details onto PositronicKit's LLM configuration.
    ///
    /// The provider string names a PositronicKit `LLMProvider`; matching is
    /// case-insensitive against its raw value. When no provider matches, `nil`
    /// is returned.
    ///
    /// - Returns: A PositronicKit LLM configuration, or `nil` when the provider
    ///   is unset or unknown.
    public func llmConfiguration() -> LLMConfiguration? {
        guard let providerName = llmProvider,
              let provider = LLMProvider.allCases.first(where: {
                  $0.rawValue.lowercased() == providerName.lowercased()
              })
        else { return nil }

        var configuration = LLMConfiguration(activeProvider: provider)
        var providerConfig = provider.providerConfiguration

        if let endpoint = llmEndpoint, !endpoint.isEmpty {
            providerConfig.endpoint = endpoint
        }
        if let apiKey = llmAPIKey, !apiKey.isEmpty {
            providerConfig.apiKey = apiKey
        }
        if let model = llmModel, !model.isEmpty {
            providerConfig.modelName = model
        }
        if let utility = llmUtilityModel, !utility.isEmpty {
            providerConfig.utilityModel = utility
        }
        if let fast = llmFastModel, !fast.isEmpty {
            providerConfig.fastModel = fast
        }

        configuration.providers[provider] = providerConfig
        return configuration
    }
}

extension LLMProvider {
    /// The configured default provider configuration for this provider.
    var providerConfiguration: ProviderConfiguration {
        .makeDefault(for: self)
    }
}
