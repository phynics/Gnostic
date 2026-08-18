// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKAnthropicProvider
import PKOllamaProvider
import PKOpenAIProvider
import PKOpenRouterProvider
import PKShared
import PositronicKit

/// Builds a configured `LanguageModel` from a CLI/PositronicKit `LLMConfiguration`.
///
/// The per-provider client factory routes the active provider to its bundled
/// client package (`PKOpenAIProvider`, `PKOpenRouterProvider`, ...) so the LLM
/// service can actually create a transport client. Shared by the CLI and the
/// serve runtime so served chat turns run against the user's configured model.
public enum ConfiguredLLMService {
    /// Creates a PositronicKit model backed by the active provider's client.
    ///
    /// - Parameter configuration: The LLM provider + endpoint/key/model settings.
    /// - Returns: A configured model, or `UnconfiguredLLMService` when the
    ///   configuration is not valid (e.g. missing provider or API key).
    public static func make(from configuration: LLMConfiguration) -> any LanguageModel {
        guard configuration.isValid else { return UnconfiguredLLMService() }
        return LLMService(configuration: configuration, clients: makeClients(for: configuration))
    }

    /// Bridges a validated Core launch-plan profile without making GnosticCore
    /// depend on CLI provider packages.
    public static func make(from profile: NodeManifest.LLMProfile) -> any LanguageModel {
        guard let provider = LLMProvider.allCases.first(where: {
            $0.rawValue.lowercased() == profile.provider.lowercased()
        }) else { return UnconfiguredLLMService() }
        var configuration = LLMConfiguration(activeProvider: provider)
        var providerConfiguration = provider.providerConfiguration
        providerConfiguration.endpoint = profile.endpoint ?? providerConfiguration.endpoint
        providerConfiguration.apiKey = profile.apiKey ?? providerConfiguration.apiKey
        providerConfiguration.modelName = profile.model ?? providerConfiguration.modelName
        providerConfiguration.utilityModel = profile.utilityModel ?? providerConfiguration.utilityModel
        providerConfiguration.fastModel = profile.fastModel ?? providerConfiguration.fastModel
        configuration.providers[provider] = providerConfiguration
        return make(from: configuration)
    }

    private static func makeClients(for configuration: LLMConfiguration) -> LLMClientSet {
        let provider = configuration.activeProvider
        let providerConfiguration = configuration.activeProviderConfiguration
        let makeClient: (LLMConfiguration) -> any LLMClientProtocol

        switch provider {
        case .openAI, .openAICompatible:
            makeClient = { configuration in
                PKOpenAIProvider.makeClient(configuration: configuration)
            }
        case .openRouter:
            makeClient = { configuration in
                PKOpenRouterProvider.makeClient(configuration: configuration)
            }
        case .ollama:
            makeClient = { configuration in
                PKOllamaProvider.makeClient(configuration: configuration)
            }
        case .anthropic:
            makeClient = { configuration in
                PKAnthropicProvider.makeClient(configuration: configuration)
            }
        }

        return LLMClientSet(
            primary: makeClient(configurationWithModel(providerConfiguration.modelName)),
            utility: makeClient(configurationWithModel(providerConfiguration.utilityModel)),
            fast: makeClient(configurationWithModel(providerConfiguration.fastModel))
        )

        func configurationWithModel(_ modelName: String) -> LLMConfiguration {
            var configured = configuration
            var providerConfiguration = configured.activeProviderConfiguration
            providerConfiguration.modelName = modelName
            configured.providers[provider] = providerConfiguration
            return configured
        }
    }
}
