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

    public var stringValue: String? {
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
}

/// The versioned, graph-shaped configuration persisted by Gnostic.
public struct NodeManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public typealias BackendConfiguration = AscendantBackendConfiguration

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

        /// Returns a copy with empty credential strings cleared to `nil`.
        ///
        /// MQTT treats a present-but-empty password as a credential on the wire,
        /// which brokers reject when no username is present. Empty values carry
        /// no authentication intent, so the canonical manifest never stores
        /// them.
        public func normalized() -> Self {
            var copy = self
            if copy.username?.isEmpty == true { copy.username = nil }
            if copy.password?.isEmpty == true { copy.password = nil }
            return copy
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

    public struct Ascendant: Codable, Equatable, Sendable {
        public typealias BackendConfiguration = AscendantBackendConfiguration
        public var id: UUID
        public var kind: String
        public var name: String
        public var description: String
        public var metadata: [String: String]
        public var backend: AscendantBackendConfiguration
        public var defaultTimelineID: UUID

        public init(
            id: UUID,
            name: String,
            defaultTimelineID: UUID,
            kind: String = "positronic",
            description: String = "",
            metadata: [String: String] = [:],
            backend: AscendantBackendConfiguration? = nil
        ) {
            self.id = id; self.kind = kind; self.name = name; self.description = description
            self.metadata = metadata; self.defaultTimelineID = defaultTimelineID
            self.backend = backend ?? .init(kind: kind)
        }

        public init(id: UUID, name: String, defaultTimelineID: UUID, backend: AscendantBackendConfiguration, kind: String? = nil, description: String = "", metadata: [String: String] = [:]) {
            self.init(id: id, name: name, defaultTimelineID: defaultTimelineID, kind: kind ?? backend.kind, description: description, metadata: metadata, backend: backend)
        }

        public var timelineID: UUID { get { defaultTimelineID } set { defaultTimelineID = newValue } }

        enum CodingKeys: String, CodingKey { case id, kind, name, description, metadata, backend, defaultTimelineID, timelineID }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "positronic"
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
            backend = try container.decode(AscendantBackendConfiguration.self, forKey: .backend)
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

    public var schemaVersion: Int
    public var broker: Broker
    public var node: Node
    public var ascendants: [Ascendant]
    public var timelines: [Timeline]
    public var workspaces: [Workspace]

    public init(schemaVersion: Int = currentSchemaVersion, broker: Broker, node: Node, ascendants: [Ascendant] = [], timelines: [Timeline] = [], workspaces: [Workspace] = []) {
        self.schemaVersion = schemaVersion; self.broker = broker; self.node = node
        self.ascendants = ascendants; self.timelines = timelines; self.workspaces = workspaces
    }

    public static func makeDefault(broker: Broker) -> Self {
        let node = UUID.makeVersion4(), ascendant = UUID.makeVersion4()
        let timeline = UUID.makeVersion4(), workspace = UUID.makeVersion4()
        return .init(broker: broker, node: .init(id: node), ascendants: [.init(id: ascendant, name: "Default Ascendant", defaultTimelineID: timeline, backend: .init(kind: "positronic"))], timelines: [.init(id: timeline, title: "Default Timeline", operatingAscendantID: ascendant)], workspaces: [.init(id: workspace, name: "Echo Workspace", uri: "echo://default")])
    }

    public static func empty(broker: Broker) -> Self { .init(broker: broker, node: .init(id: UUID.makeVersion4())) }

    public var allIDs: [UUID] { [node.id] + ascendants.map(\.id) + timelines.map(\.id) + workspaces.map(\.id) }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw NodeManifestError.unsupportedSchemaVersion(schemaVersion) }
        guard broker.port >= 1, broker.port <= 65_535, !broker.host.isEmpty, !broker.namespace.isEmpty else { throw NodeManifestError.invalidBroker }
        guard node.kind == "node" else { throw NodeManifestError.invalidKind(kind: node.kind, objectID: node.id) }
        guard ["auto", "deny"].contains(node.approvalMode), ["trace", "debug", "info", "warning", "error"].contains(node.logLevel) else { throw NodeManifestError.invalidNodeSettings }
        var ids = Set<UUID>(); for id in allIDs { guard id.isVersion4 && id.isRFC4122Variant else { throw NodeManifestError.invalidUUID(id) }; guard ids.insert(id).inserted else { throw NodeManifestError.duplicateID(id) } }
        for ascendant in ascendants {
            guard !ascendant.kind.isEmpty, !ascendant.name.isEmpty else { throw NodeManifestError.invalidKind(kind: ascendant.kind, objectID: ascendant.id) }
            guard ascendant.backend.validate() else { throw NodeManifestError.invalidBackend(ascendant.id) }
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

    /// Returns a copy with empty broker credential strings cleared.
    ///
    /// The store writes this form so the persisted manifest never records `""`
    /// where no credential was intended.
    public func normalized() -> Self {
        var copy = self
        copy.broker = copy.broker.normalized()
        return copy
    }

    /// Verifies that the broker credentials can be represented on the MQTT wire.
    ///
    /// MQTT 3.1.1 §3.1.2.9 forbids the password flag when the username flag is
    /// clear, so a password without a username is rejected before a transport
    /// connects.
    public func validateBrokerCredentials() throws {
        let broker = broker.normalized()
        guard broker.password != nil else { return }
        guard broker.username != nil else { throw NodeManifestError.passwordWithoutUsername }
    }

    public func compileLaunchPlan() throws -> NodeLaunchPlan {
        try validate(); try validateBrokerCredentials()
        return NodeLaunchPlan(node: node, broker: broker.normalized(), ascendants: ascendants, timelines: timelines, workspaces: workspaces)
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

    private var identityMap: [UUID: String] {
        var map = [node.id: node.kind]; for value in ascendants { map[value.id] = "ascendant" }; for value in timelines { map[value.id] = value.kind }; for value in workspaces { map[value.id] = value.kind }; return map
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, broker, node, ascendants, timelines, workspaces }

    /// Decodes a current-schema manifest. Any other schema version is
    /// rejected; the pre-reset v1 migration was retired after 0.4.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NodeManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        broker = try container.decode(Broker.self, forKey: .broker)
        node = try container.decode(Node.self, forKey: .node)
        ascendants = try container.decodeIfPresent([Ascendant].self, forKey: .ascendants) ?? []
        timelines = try container.decodeIfPresent([Timeline].self, forKey: .timelines) ?? []
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(broker, forKey: .broker)
        try container.encode(node, forKey: .node)
        try container.encode(ascendants, forKey: .ascendants)
        try container.encode(timelines, forKey: .timelines)
        try container.encode(workspaces, forKey: .workspaces)
    }
}

public struct NodeLaunchPlan: Codable, Equatable, Sendable {
    public let node: NodeManifest.Node
    public let broker: NodeManifest.Broker
    public let ascendants: [NodeManifest.Ascendant]
    public let timelines: [NodeManifest.Timeline]
    public let workspaces: [NodeManifest.Workspace]

    public init(node: NodeManifest.Node, broker: NodeManifest.Broker, ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) {
        self.node = node; self.broker = broker; self.ascendants = ascendants; self.timelines = timelines; self.workspaces = workspaces
    }
    public init(nodeID: UUID, broker: NodeManifest.Broker, ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) { self.init(node: .init(id: nodeID), broker: broker, ascendants: ascendants, timelines: timelines, workspaces: workspaces) }
    public var nodeID: UUID { node.id }
    public func backend(for ascendantID: UUID) -> AscendantBackendConfiguration? { ascendants.first { $0.id == ascendantID }?.backend }
}
