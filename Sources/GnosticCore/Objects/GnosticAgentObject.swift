// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// Canonical Axoloty object type identifiers advertised by Gnostic.
public enum GnosticObjectType {
    /// The object type for a projected PositronicKit agent.
    public static let agent = "me.atkn.gnostic.Agent"

    /// The object type for a projected PositronicKit timeline.
    public static let timeline = "me.atkn.gnostic.Timeline"

    /// The object type for a projected PositronicKit workspace.
    public static let workspace = "me.atkn.gnostic.Workspace"

    /// Returns whether an object type is handled by the Gnostic catalog.
    ///
    /// - Parameter objectType: A network object type.
    /// - Returns: `true` when the type is one of Gnostic's canonical types.
    public static func isSupported(_ objectType: String) -> Bool {
        [agent, timeline, workspace].contains(objectType)
    }
}

/// A safe network projection of a PositronicKit ``AgentInstance``.
public final class GnosticAgentObject: CoatyObject {
    /// The projected agent's public description.
    public var agentDescription: String

    /// The agent's primary workspace relationship, when one is assigned.
    public var primaryWorkspaceID: UUID?

    /// The agent's private timeline relationship.
    public var privateTimelineID: UUID

    /// The agent's latest recorded activity timestamp.
    public var lastActiveAt: Date

    /// The agent creation timestamp.
    public var createdAt: Date

    /// The agent's latest update timestamp.
    public var updatedAt: Date

    /// Registers Gnostic's canonical agent object type.
    public override class var objectType: String {
        register(objectType: GnosticObjectType.agent, with: self)
    }

    /// Bridges a PositronicKit agent inside Gnostic's implementation boundary.
    /// Public callers use `AscendantRuntimeIdentity` so PositronicKit remains replaceable.
    convenience init(agent: AgentInstance) {
        self.init(identity: .init(id: agent.id, name: agent.name, description: agent.description, privateTimelineID: agent.privateThreadID, primaryWorkspaceID: agent.primaryWorkspaceID, lastActiveAt: agent.lastActiveAt, createdAt: agent.createdAt, updatedAt: agent.updatedAt))
    }

    /// Creates a network projection without exposing a provider's agent type.
    public init(identity: AscendantRuntimeIdentity) {
        agentDescription = identity.description
        primaryWorkspaceID = identity.primaryWorkspaceID
        privateTimelineID = identity.privateTimelineID
        lastActiveAt = identity.lastActiveAt
        createdAt = identity.createdAt
        updatedAt = identity.updatedAt
        super.init(
            coreType: .CoatyObject,
            objectType: Self.objectType,
            objectId: CoatyUUID(uuidString: identity.id.uuidString)!,
            name: identity.name
        )
    }

    private enum CodingKeys: String, CodingKey {
        case agentDescription
        case primaryWorkspaceID
        case privateTimelineID
        case lastActiveAt
        case createdAt
        case updatedAt
    }

    /// Decodes an advertised agent projection.
    ///
    /// - Parameter decoder: The source decoder.
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentDescription = try container.decode(String.self, forKey: .agentDescription)
        primaryWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .primaryWorkspaceID)
        privateTimelineID = try container.decode(UUID.self, forKey: .privateTimelineID)
        lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        try super.init(from: decoder)
    }

    /// Encodes the safe agent projection.
    ///
    /// - Parameter encoder: The destination encoder.
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentDescription, forKey: .agentDescription)
        try container.encodeIfPresent(primaryWorkspaceID, forKey: .primaryWorkspaceID)
        try container.encode(privateTimelineID, forKey: .privateTimelineID)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
