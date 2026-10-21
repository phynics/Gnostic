// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// A read-only projection of provider fields in one Ascendant backend envelope.
///
/// This value has no resource identity and is never persisted. It lets the
/// configuration and doctor commands inspect provider settings without
/// importing the backend that consumes them.
public struct ProviderBackendConfiguration: Codable, Equatable, Sendable {
    public var provider: String?
    public var endpoint: String?
    public var model: String?
    public var utilityModel: String?
    public var fastModel: String?
    public var apiKey: String?

    public init(backend: NodeManifest.BackendConfiguration) {
        provider = backend.settings["provider"]?.stringValue
        endpoint = backend.settings["endpoint"]?.stringValue
        model = backend.settings["model"]?.stringValue
        utilityModel = backend.settings["utilityModel"]?.stringValue
        fastModel = backend.settings["fastModel"]?.stringValue
        apiKey = backend.secrets["apiKey"]?.stringValue
    }
}
