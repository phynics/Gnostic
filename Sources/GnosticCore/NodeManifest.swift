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
            self.id = id; self.name = name; self.provider = provider; self.endpoint = endpoint
            self.model = model; self.utilityModel = utilityModel; self.fastModel = fastModel; self.apiKey = apiKey
        }

        public init(id: UUID, kind _: String, provider: String, name: String = "Default LLM Profile", endpoint: String? = nil, model: String? = nil, utilityModel: String? = nil, fastModel: String? = nil, apiKey: String? = nil) {
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

        public init(id: UUID, name: String, defaultTimelineID: UUID, kind: String = "positronic", description: String = "", metadata: [String: String] = [:], llmProfileID: UUID? = nil) {
            self.id = id; self.kind = kind; self.name = name; self.description = description
            self.metadata = metadata; self.llmProfileID = llmProfileID; self.defaultTimelineID = defaultTimelineID
        }

        public init(id: UUID, name: String, llmProfileID: UUID, timelineID: UUID, kind: String = "positronic") {
            self.init(id: id, name: name, defaultTimelineID: timelineID, kind: kind, llmProfileID: llmProfileID)
        }

        public var timelineID: UUID { get { defaultTimelineID } set { defaultTimelineID = newValue } }
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
    public var llmProfiles: [LLMProfile]
    public var ascendants: [Ascendant]
    public var timelines: [Timeline]
    public var workspaces: [Workspace]

    public init(schemaVersion: Int = currentSchemaVersion, broker: Broker, node: Node, llmProfiles: [LLMProfile] = [], ascendants: [Ascendant] = [], timelines: [Timeline] = [], workspaces: [Workspace] = []) {
        self.schemaVersion = schemaVersion; self.broker = broker; self.node = node; self.llmProfiles = llmProfiles
        self.ascendants = ascendants; self.timelines = timelines; self.workspaces = workspaces
    }

    public static func makeDefault(broker: Broker) -> Self {
        let node = UUID.makeVersion4(), profile = UUID.makeVersion4(), ascendant = UUID.makeVersion4()
        let timeline = UUID.makeVersion4(), workspace = UUID.makeVersion4()
        return .init(broker: broker, node: .init(id: node), llmProfiles: [.init(id: profile, provider: "positronic")], ascendants: [.init(id: ascendant, name: "Default Ascendant", defaultTimelineID: timeline, llmProfileID: profile)], timelines: [.init(id: timeline, title: "Default Timeline", operatingAscendantID: ascendant)], workspaces: [.init(id: workspace, name: "Echo Workspace", uri: "echo://default")])
    }

    public static func empty(broker: Broker) -> Self { .init(broker: broker, node: .init(id: UUID.makeVersion4())) }
    public static func defaultManifest(broker: Broker) -> Self { makeDefault(broker: broker) }
    public var allIDs: [UUID] { [node.id] + llmProfiles.map(\.id) + ascendants.map(\.id) + timelines.map(\.id) + workspaces.map(\.id) }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw NodeManifestError.unsupportedSchemaVersion(schemaVersion) }
        guard broker.port >= 1, broker.port <= 65_535, !broker.host.isEmpty, !broker.namespace.isEmpty else { throw NodeManifestError.invalidBroker }
        guard node.kind == "node" else { throw NodeManifestError.invalidKind(kind: node.kind, objectID: node.id) }
        guard ["auto", "deny"].contains(node.approvalMode), ["trace", "debug", "info", "warning", "error"].contains(node.logLevel) else { throw NodeManifestError.invalidNodeSettings }
        var ids = Set<UUID>(); for id in allIDs { guard id.isVersion4 && id.isRFC4122Variant else { throw NodeManifestError.invalidUUID(id) }; guard ids.insert(id).inserted else { throw NodeManifestError.duplicateID(id) } }
        for profile in llmProfiles where profile.name.isEmpty || profile.provider.isEmpty { throw NodeManifestError.invalidProfile(profile.id) }
        for ascendant in ascendants {
            guard !ascendant.kind.isEmpty, !ascendant.name.isEmpty else { throw NodeManifestError.invalidKind(kind: ascendant.kind, objectID: ascendant.id) }
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
                    // A lazy external identity must never be resolved through a
                    // configured local object that happens to share its UUID.
                    guard !allIDs.contains(attachment.workspaceID) else {
                        throw NodeManifestError.duplicateID(attachment.workspaceID)
                    }
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
        try validate(); return NodeLaunchPlan(node: node, broker: broker, llmProfiles: llmProfiles, ascendants: ascendants, timelines: timelines, workspaces: workspaces)
    }

    public func redactedDescription() -> String {
        var copy = self; copy.broker.password = copy.broker.password.map { _ in "<redacted>" }
        copy.llmProfiles = copy.llmProfiles.map { var value = $0; value.apiKey = value.apiKey.map { _ in "<redacted>" }; return value }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(copy), encoding: .utf8)) ?? "{}"
    }

    private var identityMap: [UUID: String] {
        var map = [node.id: node.kind]; for value in llmProfiles { map[value.id] = "llmProfile" }; for value in ascendants { map[value.id] = value.kind }; for value in timelines { map[value.id] = value.kind }; for value in workspaces { map[value.id] = value.kind }; return map
    }
}

public struct NodeLaunchPlan: Codable, Equatable, Sendable {
    public let node: NodeManifest.Node
    public let broker: NodeManifest.Broker
    public let llmProfiles: [NodeManifest.LLMProfile]
    public let ascendants: [NodeManifest.Ascendant]
    public let timelines: [NodeManifest.Timeline]
    public let workspaces: [NodeManifest.Workspace]
    public init(node: NodeManifest.Node, broker: NodeManifest.Broker, llmProfiles: [NodeManifest.LLMProfile], ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) { self.node = node; self.broker = broker; self.llmProfiles = llmProfiles; self.ascendants = ascendants; self.timelines = timelines; self.workspaces = workspaces }
    public init(nodeID: UUID, broker: NodeManifest.Broker, llmProfiles: [NodeManifest.LLMProfile], ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline], workspaces: [NodeManifest.Workspace]) { self.init(node: .init(id: nodeID), broker: broker, llmProfiles: llmProfiles, ascendants: ascendants, timelines: timelines, workspaces: workspaces) }
    public var nodeID: UUID { node.id }
}

public enum NodeManifestError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int), invalidBroker, invalidNodeSettings, invalidUUID(UUID), invalidKind(kind: String, objectID: UUID), invalidProfile(UUID), invalidAttachment(UUID), duplicateID(UUID), duplicateAttachment(UUID, UUID), missingReference(from: UUID, to: UUID), invalidDefaultTimeline(UUID, UUID), immutableIdentity(UUID)
    public var reasonCode: String { switch self { case .unsupportedSchemaVersion: "unsupportedSchemaVersion"; case .invalidBroker: "invalidBroker"; case .invalidNodeSettings: "invalidNodeSettings"; case .invalidUUID: "invalidUUID"; case .invalidKind: "invalidKind"; case .invalidProfile: "invalidProfile"; case .invalidAttachment: "invalidAttachment"; case .duplicateID: "duplicateID"; case .duplicateAttachment: "duplicateAttachment"; case .missingReference: "missingReference"; case .invalidDefaultTimeline: "invalidDefaultTimeline"; case .immutableIdentity: "immutableIdentity" } }
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
    static func makeVersion4() -> UUID { repeat { let value = UUID(); if value.isVersion4 && value.isRFC4122Variant { return value } } while true }
}
