// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A JSON value used by backend-owned manifest settings.
public enum ManifestJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ManifestJSONValue])
    case array([ManifestJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode([String: ManifestJSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([ManifestJSONValue].self) { self = .array(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var encodedByteCount: Int {
        (try? JSONEncoder().encode(self).count) ?? Int.max
    }

    var maximumDepth: Int {
        switch self {
        case .string, .number, .bool, .null: return 1
        case let .object(values): return 1 + (values.values.map(\.maximumDepth).max() ?? 0)
        case let .array(values): return 1 + (values.map(\.maximumDepth).max() ?? 0)
        }
    }

    var entryCount: Int {
        switch self {
        case .string, .number, .bool, .null: return 1
        case let .object(values): return values.count + values.values.reduce(0) { $0 + $1.entryCount }
        case let .array(values): return values.count + values.reduce(0) { $0 + $1.entryCount }
        }
    }
}

/// The backend-owned configuration envelope attached to one Ascendant.
public struct AscendantBackendConfiguration: Codable, Equatable, Sendable {
    public static let maxJSONBytes = 64 * 1024
    public static let maxNestingDepth = 8
    public static let maxEntryCount = 256

    public var kind: String
    public var schemaVersion: Int
    public var settings: [String: ManifestJSONValue]
    public var secrets: [String: ManifestJSONValue]

    public init(
        kind: String,
        schemaVersion: Int = 1,
        settings: [String: ManifestJSONValue] = [:],
        secrets: [String: ManifestJSONValue] = [:]
    ) {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.secrets = secrets
    }

    func validate() -> Bool {
        guard !kind.isEmpty, schemaVersion >= 1 else { return false }
        guard settings.keys.allSatisfy({ !$0.isEmpty }), secrets.keys.allSatisfy({ !$0.isEmpty }) else { return false }
        guard settings.count + secrets.count <= Self.maxEntryCount else { return false }
        let values = Array(settings.values) + Array(secrets.values)
        guard values.allSatisfy({ $0.maximumDepth <= Self.maxNestingDepth && $0.entryCount <= Self.maxEntryCount }) else { return false }
        let bytes = (try? JSONEncoder().encode(self).count) ?? Int.max
        return bytes <= Self.maxJSONBytes
    }

    public typealias JSONValue = ManifestJSONValue
}

/// Compatibility spelling used by early reset consumers.
public typealias BackendConfiguration = AscendantBackendConfiguration

/// The versioned, graph-shaped configuration persisted by Gnostic.
public struct NodeManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public typealias BackendConfiguration = AscendantBackendConfiguration
    public typealias Backend = AscendantBackendConfiguration
    public typealias JSONValue = ManifestJSONValue

    public struct Broker: Codable, Equatable, Sendable {
        public var host: String
        public var port: Int
        public var namespace: String
        public var username: String?
        public var password: String?

        public init(host: String, port: Int, namespace: String, username: String? = nil, password: String? = nil) {
            self.host = host; self.port = port; self.namespace = namespace
            self.username = username; self.password = password
        }
    }

    public struct Node: Codable, Equatable, Sendable {
        public var id: UUID
        public var kind: String
        public var approvalMode: String
        public var logLevel: String

        public init(id: UUID, kind: String = "node", approvalMode: String = "auto", logLevel: String = "info") {
            self.id = id; self.kind = kind; self.approvalMode = approvalMode; self.logLevel = logLevel
        }
    }

    /// Transitional CLI projection. It is never written at the top level of
    /// manifest v2; provider semantics live in each Ascendant's backend envelope.
    public struct LLMProfile: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var provider: String
        public var endpoint: String?
        public var model: String?
        public var utilityModel: String?
        public var fastModel: String?
        public var apiKey: String?

        public var kind: String { get { "positronic" } set { _ = newValue } }

        public init(id: UUID, provider: String, name: String = "Default LLM Profile", endpoint: String? = nil, model: String? = nil, utilityModel: String? = nil, fastModel: String? = nil, apiKey: String? = nil) {
            self.id = id; self.name = name; self.provider = provider; self.endpoint = endpoint; self.model = model
            self.utilityModel = utilityModel; self.fastModel = fastModel; self.apiKey = apiKey
        }

        public init(id: UUID, kind _: String, provider: String, name: String = "Default LLM Profile", endpoint: String? = nil, model: String? = nil, utilityModel: String? = nil, fastModel: String? = nil, apiKey: String? = nil) {
            self.init(id: id, provider: provider, name: name, endpoint: endpoint, model: model, utilityModel: utilityModel, fastModel: fastModel, apiKey: apiKey)
        }
    }

    public struct Ascendant: Codable, Equatable, Sendable {
        public typealias Backend = AscendantBackendConfiguration
        public typealias BackendConfiguration = AscendantBackendConfiguration
        public var id: UUID
        public var kind: String
        public var name: String
        public var description: String
        public var metadata: [String: String]
        public var backend: AscendantBackendConfiguration
        /// Deprecated compatibility projection. It is omitted from v2 JSON.
        public var llmProfileID: UUID?
        public var defaultTimelineID: UUID

        public init(
            id: UUID,
            name: String,
            defaultTimelineID: UUID,
            kind: String = "positronic",
            description: String = "",
            metadata: [String: String] = [:],
            llmProfileID: UUID? = nil,
            backend: AscendantBackendConfiguration? = nil
        ) {
            self.id = id; self.kind = kind; self.name = name; self.description = description
            self.metadata = metadata; self.llmProfileID = llmProfileID; self.defaultTimelineID = defaultTimelineID
            self.backend = backend ?? .init(kind: kind)
        }

        public init(id: UUID, name: String, llmProfileID: UUID, timelineID: UUID, kind: String = "positronic") {
            self.init(id: id, name: name, defaultTimelineID: timelineID, kind: kind, llmProfileID: llmProfileID)
        }

        public init(id: UUID, name: String, defaultTimelineID: UUID, backend: AscendantBackendConfiguration, kind: String? = nil, description: String = "", metadata: [String: String] = [:]) {
            self.init(id: id, name: name, defaultTimelineID: defaultTimelineID, kind: kind ?? backend.kind, description: description, metadata: metadata, backend: backend)
        }

        public var timelineID: UUID { get { defaultTimelineID } set { defaultTimelineID = newValue } }

        enum CodingKeys: String, CodingKey { case id, kind, name, description, metadata, backend, llmProfileID, defaultTimelineID, timelineID }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "positronic"
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
            backend = try container.decodeIfPresent(AscendantBackendConfiguration.self, forKey: .backend) ?? .init(kind: kind)
            llmProfileID = try container.decodeIfPresent(UUID.self, forKey: .llmProfileID)
            defaultTimelineID = try container.decodeIfPresent(UUID.self, forKey: .defaultTimelineID)
                ?? container.decode(UUID.self, forKey: .timelineID)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(metadata, forKey: .metadata)
            try container.encode(backend, forKey: .backend)
            try container.encode(defaultTimelineID, forKey: .defaultTimelineID)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.name == rhs.name
                && lhs.description == rhs.description && lhs.metadata == rhs.metadata
                && lhs.backend == rhs.backend && lhs.defaultTimelineID == rhs.defaultTimelineID
        }
    }

    public enum AttachmentScope: String, Codable, Equatable, Sendable { case local, network }

    public struct WorkspaceAttachment: Codable, Equatable, Sendable {
        public typealias Scope = AttachmentScope
        public var workspaceID: UUID
        public var scope: AttachmentScope
        public var uri: String?

        public init(workspaceID: UUID, scope: AttachmentScope, uri: String? = nil) {
            self.workspaceID = workspaceID; self.scope = scope; self.uri = uri
        }
        public static func local(_ id: UUID) -> Self { .init(workspaceID: id, scope: .local) }
        public static func network(_ id: UUID, uri: String) -> Self { .init(workspaceID: id, scope: .network, uri: uri) }
    }

    public struct Timeline: Codable, Equatable, Sendable {
        public var id: UUID
        public var kind: String
        public var title: String
        public var operatingAscendantID: UUID?
        public var flags: Set<String>
        public var attachments: [WorkspaceAttachment]

        public init(id: UUID, title: String, kind: String = "timeline", operatingAscendantID: UUID? = nil, flags: Set<String> = [], attachments: [WorkspaceAttachment] = []) {
            self.id = id; self.kind = kind; self.title = title; self.operatingAscendantID = operatingAscendantID
            self.flags = flags; self.attachments = attachments
        }
        public init(id: UUID, name: String, kind: String = "timeline", workspaceIDs: [UUID] = []) {
            self.init(id: id, title: name, kind: kind, attachments: workspaceIDs.map(WorkspaceAttachment.local))
        }
        public var name: String { get { title } set { title = newValue } }
        public var workspaceIDs: [UUID] { get { attachments.map(\.workspaceID) } set { attachments = newValue.map(WorkspaceAttachment.local) } }
    }

    public struct Workspace: Codable, Equatable, Sendable {
        public var id: UUID
        public var kind: String
        public var name: String
        public var uri: String
        public init(id: UUID, name: String, uri: String, kind: String = "echo") {
            self.id = id; self.kind = kind; self.name = name; self.uri = uri
        }
    }

    public typealias BrokerConfiguration = Broker
    public typealias NodeConfiguration = Node
    public typealias LLMProfileConfiguration = LLMProfile
    public typealias AscendantConfiguration = Ascendant
    public typealias TimelineConfiguration = Timeline
    public typealias WorkspaceConfiguration = Workspace

    public var schemaVersion: Int
    public var broker: Broker
    public var node: Node
    public var ascendants: [Ascendant]
    public var timelines: [Timeline]
    public var workspaces: [Workspace]

    /// Detached profiles are retained only for old CLI resource commands.
    /// They are encoded as backend envelopes under a compatibility key and
    /// never as the removed top-level `llmProfiles` collection.
    private var detachedBackends: [AscendantBackendConfiguration]

    public init(schemaVersion: Int = currentSchemaVersion, broker: Broker, node: Node, llmProfiles: [LLMProfile] = [], ascendants: [Ascendant] = [], timelines: [Timeline] = [], workspaces: [Workspace] = []) {
        self.schemaVersion = schemaVersion; self.broker = broker; self.node = node
        self.ascendants = ascendants; self.timelines = timelines; self.workspaces = workspaces
        self.detachedBackends = []
        if !llmProfiles.isEmpty { self.llmProfiles = llmProfiles }
    }

    public static func makeDefault(broker: Broker) -> Self {
        let node = UUID.makeVersion4(), ascendant = UUID.makeVersion4()
        let timeline = UUID.makeVersion4(), workspace = UUID.makeVersion4()
        let profileID = UUID.makeVersion4()
        let backend = AscendantBackendConfiguration(kind: "positronic", settings: [
            "_profileID": .string(profileID.uuidString.lowercased()), "name": .string("Default LLM Profile"), "provider": .string("positronic")
        ])
        return .init(broker: broker, node: .init(id: node), ascendants: [.init(id: ascendant, name: "Default Ascendant", defaultTimelineID: timeline, backend: backend)], timelines: [.init(id: timeline, title: "Default Timeline", operatingAscendantID: ascendant)], workspaces: [.init(id: workspace, name: "Echo Workspace", uri: "echo://default")])
    }

    public static func empty(broker: Broker) -> Self { .init(broker: broker, node: .init(id: UUID.makeVersion4())) }
    public static func defaultManifest(broker: Broker) -> Self { makeDefault(broker: broker) }

    /// Deprecated compatibility projection. The canonical v2 representation
    /// is the backend envelope on each Ascendant.
    public var llmProfiles: [LLMProfile] {
        get {
            let attached = ascendants.compactMap { profile(for: $0) }
            return attached + detachedBackends.compactMap { profile(from: $0, fallbackID: nil) }
        }
        set { setProfiles(newValue) }
    }

    public var allIDs: [UUID] { [node.id] + llmProfiles.map(\.id) + ascendants.map(\.id) + timelines.map(\.id) + workspaces.map(\.id) }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw NodeManifestError.unsupportedSchemaVersion(schemaVersion) }
        guard broker.port >= 1, broker.port <= 65_535, !broker.host.isEmpty, !broker.namespace.isEmpty else { throw NodeManifestError.invalidBroker }
        guard node.kind == "node" else { throw NodeManifestError.invalidKind(kind: node.kind, objectID: node.id) }
        guard ["auto", "deny"].contains(node.approvalMode), ["trace", "debug", "info", "warning", "error"].contains(node.logLevel) else { throw NodeManifestError.invalidNodeSettings }
        var ids = Set<UUID>(); for id in allIDs { guard id.isVersion4 && id.isRFC4122Variant else { throw NodeManifestError.invalidUUID(id) }; guard ids.insert(id).inserted else { throw NodeManifestError.duplicateID(id) } }
        for ascendant in ascendants {
            guard !ascendant.kind.isEmpty, !ascendant.name.isEmpty else { throw NodeManifestError.invalidKind(kind: ascendant.kind, objectID: ascendant.id) }
            guard ascendant.backend.validate() else { throw NodeManifestError.invalidBackend(ascendant.id) }
            if let profile = ascendant.llmProfileID, !llmProfiles.contains(where: { $0.id == profile }) { throw NodeManifestError.missingReference(from: ascendant.id, to: profile) }
            guard let timeline = timelines.first(where: { $0.id == ascendant.defaultTimelineID }) else { throw NodeManifestError.missingReference(from: ascendant.id, to: ascendant.defaultTimelineID) }
            guard timeline.operatingAscendantID == ascendant.id else { throw NodeManifestError.invalidDefaultTimeline(ascendant.id, timeline.id) }
        }
        for timeline in timelines {
            guard timeline.kind == "timeline", !timeline.title.isEmpty else { throw NodeManifestError.invalidKind(kind: timeline.kind, objectID: timeline.id) }
            if let operatorID = timeline.operatingAscendantID, !ascendants.contains(where: { $0.id == operatorID }) { throw NodeManifestError.missingReference(from: timeline.id, to: operatorID) }
            var attachmentIDs = Set<UUID>(); for attachment in timeline.attachments {
                guard attachment.workspaceID.isVersion4 && attachment.workspaceID.isRFC4122Variant else { throw NodeManifestError.invalidUUID(attachment.workspaceID) }
                guard attachmentIDs.insert(attachment.workspaceID).inserted else { throw NodeManifestError.duplicateAttachment(timeline.id, attachment.workspaceID) }
                switch attachment.scope {
                case .local:
                    guard workspaces.contains(where: { $0.id == attachment.workspaceID }), attachment.uri == nil else { throw NodeManifestError.invalidAttachment(timeline.id) }
                case .network:
                    guard let uri = attachment.uri, !uri.isEmpty else { throw NodeManifestError.invalidAttachment(timeline.id) }
                    guard !allIDs.contains(attachment.workspaceID) else { throw NodeManifestError.duplicateID(attachment.workspaceID) }
                }
            }
        }
        for workspace in workspaces where workspace.kind.isEmpty || workspace.name.isEmpty || workspace.uri.isEmpty { throw NodeManifestError.invalidKind(kind: workspace.kind, objectID: workspace.id) }
    }

    public func validate(against original: Self) throws {
        try validate(); let current = identityMap
        for (id, kind) in original.identityMap where current[id] != nil && current[id] != kind { throw NodeManifestError.immutableIdentity(id) }
    }

    public func compileLaunchPlan() throws -> NodeLaunchPlan {
        try validate(); return NodeLaunchPlan(node: node, broker: broker, llmProfiles: llmProfiles, backends: Dictionary(uniqueKeysWithValues: ascendants.map { ($0.id, $0.backend) }), ascendants: ascendants, timelines: timelines, workspaces: workspaces)
    }

    public func redactedDescription() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let object = try? JSONSerialization.jsonObject(with: data) else { return "{}" }
        func redact(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { result, pair in
                    result[pair.key] = ["secrets", "password"].contains(pair.key) ? "<redacted>" : redact(pair.value)
                }
            }
            if let array = value as? [Any] { return array.map(redact) }
            return value
        }
        guard let redacted = try? JSONSerialization.data(withJSONObject: redact(object), options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: redacted, encoding: .utf8) ?? "{}"
    }

    /// Converts a validated v1 manifest to canonical v2 without changing any
    /// Node, Ascendant, Timeline, or Workspace identity.
    public func migratedToV2() throws -> Self {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        try copy.validate()
        return copy
    }

    private var identityMap: [UUID: String] {
        var map = [node.id: node.kind]; for value in llmProfiles { map[value.id] = "llmProfile" }; for value in ascendants { map[value.id] = "ascendant" }; for value in timelines { map[value.id] = value.kind }; for value in workspaces { map[value.id] = value.kind }; return map
    }

    private func profile(for ascendant: Ascendant) -> LLMProfile? {
            profile(from: ascendant.backend, fallbackID: ascendant.llmProfileID ?? encodedProfileID(in: ascendant.backend) ?? stableProfileID(for: ascendant.id))
    }

    private func profile(from backend: AscendantBackendConfiguration, fallbackID: UUID?) -> LLMProfile? {
        guard backend.kind == "positronic", let provider = backend.settings["provider"]?.stringValue, !provider.isEmpty else { return nil }
        let encodedID = backend.settings["_profileID"]?.stringValue.flatMap(UUID.init(uuidString:))
        return .init(
            id: fallbackID ?? encodedID ?? UUID.makeVersion4(),
            provider: provider,
            name: backend.settings["name"]?.stringValue ?? "Default LLM Profile",
            endpoint: backend.settings["endpoint"]?.stringValue,
            model: backend.settings["model"]?.stringValue,
            utilityModel: backend.settings["utilityModel"]?.stringValue,
            fastModel: backend.settings["fastModel"]?.stringValue,
            apiKey: backend.secrets["apiKey"]?.stringValue
        )
    }

    private func encodedProfileID(in backend: AscendantBackendConfiguration) -> UUID? {
        backend.settings["_profileID"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    private mutating func setProfiles(_ profiles: [LLMProfile], attachUnreferenced: Bool = true, keepDetached: Bool = true) {
        var assigned = Set<Int>()
        let hasExplicitReferences = ascendants.contains { $0.llmProfileID != nil }
        for index in ascendants.indices {
            let profileIndex = profiles.firstIndex(where: { $0.id == ascendants[index].llmProfileID })
                ?? (hasExplicitReferences || !attachUnreferenced ? nil : profiles.enumerated().first(where: { !assigned.contains($0.offset) })?.offset)
            guard let profileIndex else {
                ascendants[index].backend = .init(kind: ascendants[index].kind)
                ascendants[index].llmProfileID = nil
                continue
            }
            let profile = profiles[profileIndex]
            assigned.insert(profileIndex)
            guard ascendants[index].kind == "positronic" else { continue }
            let isSharedLegacyProfile = ascendants.filter { $0.llmProfileID == profile.id }.count > 1
            ascendants[index].backend = backend(from: profile, kind: ascendants[index].kind, includeProfileID: !isSharedLegacyProfile)
            ascendants[index].llmProfileID = isSharedLegacyProfile ? stableProfileID(for: ascendants[index].id) : profile.id
        }
        detachedBackends = keepDetached ? profiles.enumerated().compactMap { index, profile in
            assigned.contains(index) ? nil : backend(from: profile, kind: "positronic", includeProfileID: true)
        } : []
    }

    private func backend(from profile: LLMProfile, kind: String, includeProfileID: Bool) -> AscendantBackendConfiguration {
        var settings: [String: ManifestJSONValue] = ["name": .string(profile.name), "provider": .string(profile.provider)]
        if includeProfileID { settings["_profileID"] = .string(profile.id.uuidString.lowercased()) }
        if let endpoint = profile.endpoint { settings["endpoint"] = .string(endpoint) }
        if let model = profile.model { settings["model"] = .string(model) }
        if let utility = profile.utilityModel { settings["utilityModel"] = .string(utility) }
        if let fast = profile.fastModel { settings["fastModel"] = .string(fast) }
        var secrets: [String: ManifestJSONValue] = [:]
        if let apiKey = profile.apiKey { secrets["apiKey"] = .string(apiKey) }
        return .init(kind: kind, settings: settings, secrets: secrets)
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, broker, node, ascendants, timelines, workspaces, backendCatalog, llmProfiles }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        broker = try container.decode(Broker.self, forKey: .broker)
        node = try container.decode(Node.self, forKey: .node)
        ascendants = try container.decodeIfPresent([Ascendant].self, forKey: .ascendants) ?? []
        timelines = try container.decodeIfPresent([Timeline].self, forKey: .timelines) ?? []
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        detachedBackends = try container.decodeIfPresent([AscendantBackendConfiguration].self, forKey: .backendCatalog) ?? []
        let profiles = try container.decodeIfPresent([LLMProfile].self, forKey: .llmProfiles) ?? []
        if schemaVersion != 1, container.contains(.llmProfiles) {
            throw DecodingError.dataCorruptedError(forKey: .llmProfiles, in: container, debugDescription: "Manifest v2 does not accept a top-level llmProfiles collection")
        }
        if schemaVersion == 1 {
            setProfiles(profiles, attachUnreferenced: false, keepDetached: false)
        }
    }

    private func stableProfileID(for ascendantID: UUID) -> UUID {
        let source = Array(ascendantID.uuidString.uppercased())
        guard source.count == 36, let value = Int(String(source[35]), radix: 16) else { return ascendantID }
        var result = source
        result[35] = Character(String(format: "%X", value ^ 0xF))
        return UUID(uuidString: String(result)) ?? ascendantID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(broker, forKey: .broker)
        try container.encode(node, forKey: .node)
        try container.encode(ascendants, forKey: .ascendants)
        try container.encode(timelines, forKey: .timelines)
        try container.encode(workspaces, forKey: .workspaces)
        if !detachedBackends.isEmpty { try container.encode(detachedBackends, forKey: .backendCatalog) }
    }
}

public struct NodeLaunchPlan: Codable, Equatable, Sendable {
    public let node: NodeManifest.Node
    public let broker: NodeManifest.Broker
    public let llmProfiles: [NodeManifest.LLMProfile]
    public let backends: [UUID: AscendantBackendConfiguration]
    public let ascendants: [NodeManifest.Ascendant]
    public let timelines: [NodeManifest.Timeline]
    public let workspaces: [NodeManifest.Workspace]

    public init(node: NodeManifest.Node, broker: NodeManifest.Broker, llmProfiles: [NodeManifest.LLMProfile], backends: [UUID: AscendantBackendConfiguration] = [:], ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) {
        self.node = node; self.broker = broker; self.llmProfiles = llmProfiles; self.backends = backends; self.ascendants = ascendants; self.timelines = timelines; self.workspaces = workspaces
    }
    public init(nodeID: UUID, broker: NodeManifest.Broker, llmProfiles: [NodeManifest.LLMProfile], backends: [UUID: AscendantBackendConfiguration] = [:], ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) { self.init(node: .init(id: nodeID), broker: broker, llmProfiles: llmProfiles, backends: backends, ascendants: ascendants, timelines: timelines, workspaces: workspaces) }
    public var nodeID: UUID { node.id }
    public func backend(for ascendantID: UUID) -> AscendantBackendConfiguration? { backends[ascendantID] ?? ascendants.first { $0.id == ascendantID }?.backend }
    public func profile(for ascendantID: UUID) -> NodeManifest.LLMProfile? {
        let ascendant = ascendants.first { $0.id == ascendantID }
        if let profileID = ascendant?.llmProfileID, let profile = llmProfiles.first(where: { $0.id == profileID }) { return profile }
        guard let backend = backend(for: ascendantID), backend.kind == "positronic",
              let provider = backend.settings["provider"]?.stringValue else { return nil }
        let profileID = backend.settings["_profileID"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? ascendantID
        return .init(
            id: profileID,
            provider: provider,
            name: backend.settings["name"]?.stringValue ?? "Default LLM Profile",
            endpoint: backend.settings["endpoint"]?.stringValue,
            model: backend.settings["model"]?.stringValue,
            utilityModel: backend.settings["utilityModel"]?.stringValue,
            fastModel: backend.settings["fastModel"]?.stringValue,
            apiKey: backend.secrets["apiKey"]?.stringValue
        )
    }
}
