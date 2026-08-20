// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// CLI-only ergonomic translation for the Positronic backend envelope.
/// Core persists only opaque backend settings and secrets.
public struct PositronicProfile: Codable, Equatable, Sendable {
    public var id: UUID
    public var ascendantID: UUID
    public var name: String
    public var provider: String
    public var endpoint: String?
    public var model: String?
    public var utilityModel: String?
    public var fastModel: String?
    public var apiKey: String?

    public init(id: UUID, ascendantID: UUID, provider: String, name: String = "Default LLM Profile", endpoint: String? = nil, model: String? = nil, utilityModel: String? = nil, fastModel: String? = nil, apiKey: String? = nil) {
        self.id = id; self.ascendantID = ascendantID; self.name = name; self.provider = provider
        self.endpoint = endpoint; self.model = model; self.utilityModel = utilityModel; self.fastModel = fastModel; self.apiKey = apiKey
    }

    public init(id: UUID, kind _: String, provider: String, name: String = "Default LLM Profile", endpoint: String? = nil, model: String? = nil, utilityModel: String? = nil, fastModel: String? = nil, apiKey: String? = nil) {
        self.init(id: id, ascendantID: id, provider: provider, name: name, endpoint: endpoint, model: model, utilityModel: utilityModel, fastModel: fastModel, apiKey: apiKey)
    }

    public init(id: UUID, provider: String, name: String = "Default LLM Profile", endpoint: String? = nil, model: String? = nil, utilityModel: String? = nil, fastModel: String? = nil, apiKey: String? = nil) {
        self.init(id: id, ascendantID: id, provider: provider, name: name, endpoint: endpoint, model: model, utilityModel: utilityModel, fastModel: fastModel, apiKey: apiKey)
    }

    init(ascendant: NodeManifest.Ascendant) {
        let backend = ascendant.backend
        id = backend.settings["_legacyID"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? ascendant.id
        ascendantID = ascendant.id
        provider = backend.settings["provider"]?.stringValue ?? "positronic"
        name = backend.settings["name"]?.stringValue ?? "Default LLM Profile"
        endpoint = backend.settings["endpoint"]?.stringValue
        model = backend.settings["model"]?.stringValue
        utilityModel = backend.settings["utilityModel"]?.stringValue
        fastModel = backend.settings["fastModel"]?.stringValue
        apiKey = backend.secrets["apiKey"]?.stringValue
    }

    func backend(kind: String = "positronic") -> AscendantBackendConfiguration {
        var settings: [String: ManifestJSONValue] = [
            "_legacyID": .string(id.uuidString.lowercased()),
            "name": .string(name),
            "provider": .string(provider),
        ]
        if let endpoint { settings["endpoint"] = .string(endpoint) }
        if let model { settings["model"] = .string(model) }
        if let utilityModel { settings["utilityModel"] = .string(utilityModel) }
        if let fastModel { settings["fastModel"] = .string(fastModel) }
        var secrets: [String: ManifestJSONValue] = [:]
        if let apiKey { secrets["apiKey"] = .string(apiKey) }
        return .init(kind: kind, settings: settings, secrets: secrets)
    }
}

public extension NodeManifest {
    init(schemaVersion: Int = NodeManifest.currentSchemaVersion, broker: Broker, node: Node, llmProfiles: [PositronicProfile], ascendants: [Ascendant] = [], timelines: [Timeline] = [], workspaces: [Workspace] = []) {
        var adjusted = ascendants
        for index in adjusted.indices {
            if let profileID = adjusted[index].llmProfileID,
               let profile = llmProfiles.first(where: { $0.id == profileID }) {
                adjusted[index].backend = profile.backend(kind: adjusted[index].kind)
            }
        }
        self.init(schemaVersion: schemaVersion, broker: broker, node: node, ascendants: adjusted, timelines: timelines, workspaces: workspaces)
    }

    /// CLI-only profile projection; it never creates detached state.
    var llmProfiles: [PositronicProfile] {
        get { ascendants.filter { $0.backend.kind == "positronic" }.map(PositronicProfile.init) }
        set { replacePositronicProfiles(newValue) }
    }

    mutating func replacePositronicProfiles(_ profiles: [PositronicProfile]) {
        var byAscendant = Dictionary(uniqueKeysWithValues: profiles.map { ($0.ascendantID, $0) })
        for index in ascendants.indices where ascendants[index].backend.kind == "positronic" {
            if let profile = byAscendant.removeValue(forKey: ascendants[index].id) {
                ascendants[index].backend = profile.backend()
            } else {
                ascendants[index].backend = .init(kind: "positronic")
            }
        }
    }
}

public extension NodeManifest.Ascendant {
    init(id: UUID, name: String, defaultTimelineID: UUID, kind: String = "positronic", description: String = "", metadata: [String: String] = [:], llmProfileID: UUID?) {
        self.init(id: id, name: name, defaultTimelineID: defaultTimelineID, kind: kind, description: description, metadata: metadata, backend: .init(kind: kind))
        self.llmProfileID = llmProfileID
    }

    /// Compatibility view used only by CLI output and command parsing.
    var llmProfileID: UUID? {
        get { backend.settings["_legacyID"]?.stringValue.flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue {
                backend.settings["_legacyID"] = .string(newValue.uuidString.lowercased())
            } else {
                backend.settings.removeValue(forKey: "_legacyID")
            }
        }
    }
}
