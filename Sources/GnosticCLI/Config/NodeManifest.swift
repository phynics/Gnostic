// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The versioned, graph-shaped configuration persisted by Gnostic.
public struct NodeManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Broker: Codable, Equatable, Sendable {
        public var host: String
        public var port: Int
        public var namespace: String
        public var username: String?
        public var password: String?

        public init(host: String, port: Int, namespace: String, username: String? = nil, password: String? = nil) {
            self.host = host
            self.port = port
            self.namespace = namespace
            self.username = username
            self.password = password
        }
    }

    public struct Node: Codable, Equatable, Sendable {
        public var id: UUID
        public var kind: String
        public var approvalMode: String
        public var logLevel: String

        public init(id: UUID, kind: String = "node", approvalMode: String = "auto", logLevel: String = "info") {
            self.id = id
            self.kind = kind
            self.approvalMode = approvalMode
            self.logLevel = logLevel
        }
    }

    public struct LLMProfile: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var provider: String
        public var endpoint: String?
        public var model: String?
        public var utilityModel: String?
        public var fastModel: String?
        public var apiKey: String?

        /// Compatibility view for the original draft; profile kinds are not a v1 field.
        public var kind: String {
            get { "positronic" }
            set { _ = newValue }
        }

        public init(
            id: UUID,
            provider: String,
            name: String = "Default LLM Profile",
            endpoint: String? = nil,
            model: String? = nil,
            utilityModel: String? = nil,
            fastModel: String? = nil,
            apiKey: String? = nil
        ) {
            self.id = id
            self.name = name
            self.provider = provider
            self.endpoint = endpoint
            self.model = model
            self.utilityModel = utilityModel
            self.fastModel = fastModel
            self.apiKey = apiKey
        }

        /// Compatibility initializer for the original draft, which exposed a non-schema `kind`.
        public init(
            id: UUID,
            kind _: String,
            provider: String,
            name: String = "Default LLM Profile",
            endpoint: String? = nil,
            model: String? = nil,
            utilityModel: String? = nil,
            fastModel: String? = nil,
            apiKey: String? = nil
        ) {
            self.init(id: id, provider: provider, name: name, endpoint: endpoint, model: model, utilityModel: utilityModel, fastModel: fastModel, apiKey: apiKey)
        }
    }

    public struct Ascendant: Codable, Equatable, Sendable {
        public var id: UUID
        public var kind: String
        public var name: String
        public var description: String
        public var metadata: [String: String]
        public var llmProfileID: UUID?
        public var defaultTimelineID: UUID

        public init(
            id: UUID,
            name: String,
            defaultTimelineID: UUID,
            kind: String = "positronic",
            description: String = "",
            metadata: [String: String] = [:],
            llmProfileID: UUID? = nil
        ) {
            self.id = id
            self.kind = kind
            self.name = name
            self.description = description
            self.metadata = metadata
            self.llmProfileID = llmProfileID
            self.defaultTimelineID = defaultTimelineID
        }

        /// Compatibility initializer for the original draft spelling.
        public init(id: UUID, name: String, llmProfileID: UUID, timelineID: UUID, kind: String = "positronic") {
            self.init(id: id, name: name, defaultTimelineID: timelineID, kind: kind, llmProfileID: llmProfileID)
        }

        /// Compatibility view for callers that used the draft spelling.
        public var timelineID: UUID {
            get { defaultTimelineID }
            set { defaultTimelineID = newValue }
        }
    }

    public enum AttachmentScope: String, Codable, Equatable, Sendable {
        case local
        case network
    }

    public struct WorkspaceAttachment: Codable, Equatable, Sendable {
        public typealias Scope = AttachmentScope
        public var workspaceID: UUID
        public var scope: AttachmentScope
        /// A network URI is retained so runtime discovery can resolve it lazily.
        /// Local attachments use the URI on the configured Workspace instead.
        public var uri: String?

        public init(workspaceID: UUID, scope: AttachmentScope, uri: String? = nil) {
            self.workspaceID = workspaceID
            self.scope = scope
            self.uri = uri
        }

        public static func local(_ workspaceID: UUID) -> WorkspaceAttachment {
            .init(workspaceID: workspaceID, scope: .local)
        }

        public static func network(_ workspaceID: UUID, uri: String) -> WorkspaceAttachment {
            .init(workspaceID: workspaceID, scope: .network, uri: uri)
        }
    }

    public struct Timeline: Codable, Equatable, Sendable {
        public var id: UUID
        public var kind: String
        public var title: String
        public var operatingAscendantID: UUID?
        public var flags: Set<String>
        public var attachments: [WorkspaceAttachment]

        public init(
            id: UUID,
            title: String,
            kind: String = "timeline",
            operatingAscendantID: UUID? = nil,
            flags: Set<String> = [],
            attachments: [WorkspaceAttachment] = []
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.operatingAscendantID = operatingAscendantID
            self.flags = flags
            self.attachments = attachments
        }

        /// Compatibility initializer for the original draft spelling.
        public init(id: UUID, name: String, kind: String = "timeline", workspaceIDs: [UUID] = []) {
            self.init(id: id, title: name, kind: kind, attachments: workspaceIDs.map(WorkspaceAttachment.local))
        }

        public var name: String {
            get { title }
            set { title = newValue }
        }

        public var workspaceIDs: [UUID] {
            get { attachments.map(\.workspaceID) }
            set { attachments = newValue.map(WorkspaceAttachment.local) }
        }
    }

    public struct Workspace: Codable, Equatable, Sendable {
        public var id: UUID
        public var kind: String
        public var name: String
        public var uri: String

        public init(id: UUID, name: String, uri: String, kind: String = "echo") {
            self.id = id
            self.kind = kind
            self.name = name
            self.uri = uri
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
    public var llmProfiles: [LLMProfile]
    public var ascendants: [Ascendant]
    public var timelines: [Timeline]
    public var workspaces: [Workspace]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        broker: Broker,
        node: Node,
        llmProfiles: [LLMProfile] = [],
        ascendants: [Ascendant] = [],
        timelines: [Timeline] = [],
        workspaces: [Workspace] = []
    ) {
        self.schemaVersion = schemaVersion
        self.broker = broker
        self.node = node
        self.llmProfiles = llmProfiles
        self.ascendants = ascendants
        self.timelines = timelines
        self.workspaces = workspaces
    }

    /// Creates the graph used by `config init` and legacy migration.
    public static func makeDefault(broker: Broker) -> NodeManifest {
        let nodeID = UUID.makeVersion4()
        let profileID = UUID.makeVersion4()
        let ascendantID = UUID.makeVersion4()
        let timelineID = UUID.makeVersion4()
        let workspaceID = UUID.makeVersion4()
        return NodeManifest(
            broker: broker,
            node: Node(id: nodeID),
            llmProfiles: [LLMProfile(id: profileID, provider: "positronic")],
            ascendants: [Ascendant(id: ascendantID, name: "Default Ascendant", defaultTimelineID: timelineID, llmProfileID: profileID)],
            timelines: [Timeline(id: timelineID, title: "Default Timeline", operatingAscendantID: ascendantID)],
            workspaces: [Workspace(id: workspaceID, name: "Echo Workspace", uri: "echo://default")]
        )
    }

    /// Creates a valid graph with no configured modules. Used by compatibility mutations.
    public static func empty(broker: Broker) -> NodeManifest {
        NodeManifest(broker: broker, node: Node(id: UUID.makeVersion4()))
    }

    public static func defaultManifest(broker: Broker) -> NodeManifest { makeDefault(broker: broker) }

    public var allIDs: [UUID] {
        [node.id] + llmProfiles.map(\.id) + ascendants.map(\.id) + timelines.map(\.id) + workspaces.map(\.id)
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NodeManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard broker.port >= 1, broker.port <= 65_535, !broker.host.isEmpty, !broker.namespace.isEmpty else {
            throw NodeManifestError.invalidBroker
        }
        guard node.kind == "node" else { throw NodeManifestError.invalidKind(kind: node.kind, objectID: node.id) }
        guard ["auto", "deny"].contains(node.approvalMode), ["trace", "debug", "info", "warning", "error"].contains(node.logLevel) else {
            throw NodeManifestError.invalidNodeSettings
        }

        for id in allIDs {
            guard id.isVersion4, id.isRFC4122Variant else { throw NodeManifestError.invalidUUID(id) }
        }
        var seen = Set<UUID>()
        for id in allIDs where !seen.insert(id).inserted {
            throw NodeManifestError.duplicateID(id)
        }
        for profile in llmProfiles {
            guard !profile.name.isEmpty, !profile.provider.isEmpty else {
                throw NodeManifestError.invalidProfile(profile.id)
            }
        }
        for ascendant in ascendants {
            guard ascendant.kind == "positronic", !ascendant.name.isEmpty else {
                throw NodeManifestError.invalidKind(kind: ascendant.kind, objectID: ascendant.id)
            }
            if let profileID = ascendant.llmProfileID, !llmProfiles.contains(where: { $0.id == profileID }) {
                throw NodeManifestError.missingReference(from: ascendant.id, to: profileID)
            }
            guard let timeline = timelines.first(where: { $0.id == ascendant.defaultTimelineID }) else {
                throw NodeManifestError.missingReference(from: ascendant.id, to: ascendant.defaultTimelineID)
            }
            guard timeline.operatingAscendantID == ascendant.id else {
                throw NodeManifestError.invalidDefaultTimeline(ascendant.id, timeline.id)
            }
        }
        for timeline in timelines {
            guard timeline.kind == "timeline", !timeline.title.isEmpty else {
                throw NodeManifestError.invalidKind(kind: timeline.kind, objectID: timeline.id)
            }
            if let operatorID = timeline.operatingAscendantID, !ascendants.contains(where: { $0.id == operatorID }) {
                throw NodeManifestError.missingReference(from: timeline.id, to: operatorID)
            }
            var attachmentIDs = Set<UUID>()
            for attachment in timeline.attachments {
                guard attachment.workspaceID.isVersion4, attachment.workspaceID.isRFC4122Variant else {
                    throw NodeManifestError.invalidUUID(attachment.workspaceID)
                }
                guard attachmentIDs.insert(attachment.workspaceID).inserted else {
                    throw NodeManifestError.duplicateAttachment(timeline.id, attachment.workspaceID)
                }
                switch attachment.scope {
                case .local:
                    guard workspaces.contains(where: { $0.id == attachment.workspaceID }) else {
                        throw NodeManifestError.missingReference(from: timeline.id, to: attachment.workspaceID)
                    }
                    guard attachment.uri == nil else { throw NodeManifestError.invalidAttachment(timeline.id) }
                case .network:
                    guard let uri = attachment.uri, !uri.isEmpty else { throw NodeManifestError.invalidAttachment(timeline.id) }
                }
            }
        }
        for workspace in workspaces {
            guard workspace.kind == "echo", !workspace.name.isEmpty, !workspace.uri.isEmpty else {
                throw NodeManifestError.invalidKind(kind: workspace.kind, objectID: workspace.id)
            }
        }
    }

    /// Existing objects may be removed, but an existing ID cannot change type.
    public func validate(against original: NodeManifest) throws {
        try validate()
        let current = identityMap
        for (id, kind) in original.identityMap {
            if let currentKind = current[id], currentKind != kind {
                throw NodeManifestError.immutableIdentity(id)
            }
        }
    }

    public func compileLaunchPlan() throws -> NodeLaunchPlan {
        try validate()
        return NodeLaunchPlan(node: node, broker: broker, llmProfiles: llmProfiles, ascendants: ascendants, timelines: timelines, workspaces: workspaces)
    }

    public func redactedDescription() -> String {
        var copy = self
        copy.broker.password = copy.broker.password.map { _ in "<redacted>" }
        copy.llmProfiles = copy.llmProfiles.map { profile in
            var profile = profile
            profile.apiKey = profile.apiKey.map { _ in "<redacted>" }
            return profile
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(copy), encoding: .utf8)) ?? "{}"
    }

    private var identityMap: [UUID: String] {
        var result = [node.id: node.kind]
        for object in llmProfiles { result[object.id] = "llmProfile" }
        for object in ascendants { result[object.id] = object.kind }
        for object in timelines { result[object.id] = object.kind }
        for object in workspaces { result[object.id] = object.kind }
        return result
    }
}

public struct NodeLaunchPlan: Codable, Equatable, Sendable {
    public let node: NodeManifest.Node
    public let broker: NodeManifest.Broker
    public let llmProfiles: [NodeManifest.LLMProfile]
    public let ascendants: [NodeManifest.Ascendant]
    public let timelines: [NodeManifest.Timeline]
    public let workspaces: [NodeManifest.Workspace]

    public init(node: NodeManifest.Node, broker: NodeManifest.Broker, llmProfiles: [NodeManifest.LLMProfile], ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) {
        self.node = node
        self.broker = broker
        self.llmProfiles = llmProfiles
        self.ascendants = ascendants
        self.timelines = timelines
        self.workspaces = workspaces
    }

    /// Compatibility initializer for the original launch-plan spelling.
    public init(nodeID: UUID, broker: NodeManifest.Broker, llmProfiles: [NodeManifest.LLMProfile], ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) {
        self.init(node: .init(id: nodeID), broker: broker, llmProfiles: llmProfiles, ascendants: ascendants, timelines: timelines, workspaces: workspaces)
    }

    public var nodeID: UUID { node.id }
}

public enum NodeManifestError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidBroker
    case invalidNodeSettings
    case invalidUUID(UUID)
    case invalidKind(kind: String, objectID: UUID)
    case invalidProfile(UUID)
    case invalidAttachment(UUID)
    case duplicateID(UUID)
    case duplicateAttachment(UUID, UUID)
    case missingReference(from: UUID, to: UUID)
    case invalidDefaultTimeline(UUID, UUID)
    case immutableIdentity(UUID)

    public var reasonCode: String {
        switch self {
        case .unsupportedSchemaVersion: "unsupportedSchemaVersion"
        case .invalidBroker: "invalidBroker"
        case .invalidNodeSettings: "invalidNodeSettings"
        case .invalidUUID: "invalidUUID"
        case .invalidKind: "invalidKind"
        case .invalidProfile: "invalidProfile"
        case .invalidAttachment: "invalidAttachment"
        case .duplicateID: "duplicateID"
        case .duplicateAttachment: "duplicateAttachment"
        case .missingReference: "missingReference"
        case .invalidDefaultTimeline: "invalidDefaultTimeline"
        case .immutableIdentity: "immutableIdentity"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version): "Unsupported manifest schema version \(version)."
        case .invalidBroker: "The manifest broker configuration is invalid."
        case .invalidNodeSettings: "The manifest node approval mode or log level is invalid."
        case let .invalidUUID(id): "Manifest object \(id.uuidString) must be a version 4 RFC 4122 UUID."
        case let .invalidKind(kind, id): "Manifest object \(id.uuidString) has invalid kind '\(kind)'."
        case let .invalidProfile(id): "LLM profile \(id.uuidString) is missing a name or provider."
        case let .invalidAttachment(id): "Timeline \(id.uuidString) has an invalid Workspace attachment."
        case let .duplicateID(id): "Manifest object ID \(id.uuidString) is not unique."
        case let .duplicateAttachment(timeline, workspace): "Timeline \(timeline.uuidString) attaches Workspace \(workspace.uuidString) more than once."
        case let .missingReference(from, to): "Manifest object \(from.uuidString) references missing object \(to.uuidString)."
        case let .invalidDefaultTimeline(ascendant, timeline): "Ascendant \(ascendant.uuidString)'s default Timeline \(timeline.uuidString) is not operated by that Ascendant."
        case let .immutableIdentity(id): "Manifest object \(id.uuidString) changed its immutable identity or kind."
        }
    }
}

public extension UUID {
    var isVersion4: Bool { withUnsafeBytes(of: uuid) { $0[6] >> 4 == 4 } }
    var isRFC4122Variant: Bool { withUnsafeBytes(of: uuid) { $0[8] & 0xc0 == 0x80 } }

    static func makeVersion4() -> UUID {
        while true {
            let candidate = UUID()
            if candidate.isVersion4, candidate.isRFC4122Variant { return candidate }
        }
    }
}
