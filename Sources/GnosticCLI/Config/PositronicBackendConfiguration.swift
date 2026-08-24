// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// Positronic-specific CLI translation for one Ascendant backend envelope.
///
/// This value has no resource identity and is never persisted separately from
/// the selected Ascendant. Unknown backend settings and secrets are preserved
/// when the translation is applied to an existing envelope.
public struct PositronicBackendConfiguration: Codable, Equatable, Sendable {
    public var provider: String?
    public var endpoint: String?
    public var model: String?
    public var utilityModel: String?
    public var fastModel: String?
    public var apiKey: String?

    public init(
        provider: String? = nil,
        endpoint: String? = nil,
        model: String? = nil,
        utilityModel: String? = nil,
        fastModel: String? = nil,
        apiKey: String? = nil
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.utilityModel = utilityModel
        self.fastModel = fastModel
        self.apiKey = apiKey
    }

    public init(backend: NodeManifest.BackendConfiguration) {
        provider = backend.settings["provider"]?.stringValue
        endpoint = backend.settings["endpoint"]?.stringValue
        model = backend.settings["model"]?.stringValue
        utilityModel = backend.settings["utilityModel"]?.stringValue
        fastModel = backend.settings["fastModel"]?.stringValue
        apiKey = backend.secrets["apiKey"]?.stringValue
    }

    /// Applies only the known Positronic fields to one existing envelope.
    public func applying(
        to existing: NodeManifest.BackendConfiguration = .init(kind: "positronic")
    ) -> NodeManifest.BackendConfiguration {
        var result = existing
        result.kind = "positronic"
        result.settings.removeValue(forKey: "_legacyID")
        if let provider { result.settings["provider"] = .string(provider) }
        if let endpoint { result.settings["endpoint"] = .string(endpoint) }
        if let model { result.settings["model"] = .string(model) }
        if let utilityModel { result.settings["utilityModel"] = .string(utilityModel) }
        if let fastModel { result.settings["fastModel"] = .string(fastModel) }
        if let apiKey { result.secrets["apiKey"] = .string(apiKey) }
        return result
    }
}
