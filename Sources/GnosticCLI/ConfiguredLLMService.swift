// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKAnthropicProvider
import PKOllamaProvider
import PKOpenAIProvider
import PKOpenRouterProvider
import PKContracts
import PositronicKit

/// Builds a configured `LanguageModel` from a CLI/PositronicKit `LLMConfiguration`.
///
/// The per-provider client factory routes the active provider to its bundled
/// client package (`PKOpenAIProvider`, `PKOpenRouterProvider`, ...) so the LLM
/// service can actually create a transport client. Shared by the CLI and the
/// serve runtime so served Turns run against the user's configured model.
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

    /// Bridges one validated Positronic backend envelope without making
    /// GnosticCore depend on CLI provider packages.
    public static func make(from backend: PositronicBackendConfiguration) -> any LanguageModel {
        guard let providerName = backend.provider,
              let provider = LLMProvider.allCases.first(where: {
            $0.rawValue.lowercased() == providerName.lowercased()
        }) else { return UnconfiguredLLMService() }
        var configuration = LLMConfiguration(activeProvider: provider)
        var providerConfiguration = provider.providerConfiguration
        providerConfiguration.endpoint = backend.endpoint ?? providerConfiguration.endpoint
        providerConfiguration.apiKey = backend.apiKey ?? providerConfiguration.apiKey
        providerConfiguration.modelName = backend.model ?? providerConfiguration.modelName
        providerConfiguration.utilityModel = backend.utilityModel ?? providerConfiguration.utilityModel
        providerConfiguration.fastModel = backend.fastModel ?? providerConfiguration.fastModel
        configuration.providers[provider] = providerConfiguration
        return make(from: configuration)
    }

    private static func makeClients(for configuration: LLMConfiguration) -> LLMClientSet {
        switch configuration.activeProvider {
        case .openAI, .openAICompatible:
            return makeClients(for: configuration, using: PKOpenAIProvider.self)
        case .openRouter:
            return makeClients(for: configuration, using: PKOpenRouterProvider.self)
        case .ollama:
            return makeClients(for: configuration, using: PKOllamaProvider.self)
        case .anthropic:
            return makeClients(for: configuration, using: PKAnthropicProvider.self)
        }
    }

    private static func makeClients<Factory: LLMProviderFactory>(
        for configuration: LLMConfiguration,
        using _: Factory.Type
    ) -> LLMClientSet {
        let providerConfiguration = configuration.activeProviderConfiguration
        return LLMClientSet(
            primary: Factory.makeClient(configuration: configurationWithModel(providerConfiguration.modelName)),
            utility: Factory.makeClient(configuration: configurationWithModel(providerConfiguration.utilityModel)),
            fast: Factory.makeClient(configuration: configurationWithModel(providerConfiguration.fastModel))
        )

        func configurationWithModel(_ modelName: String) -> LLMConfiguration {
            var configured = configuration
            var providerConfiguration = configured.activeProviderConfiguration
            providerConfiguration.modelName = modelName
            configured.providers[configuration.activeProvider] = providerConfiguration
            return configured
        }
    }
}
