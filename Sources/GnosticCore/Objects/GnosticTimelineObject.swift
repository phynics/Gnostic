// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PositronicKit

/// A safe network projection of a PositronicKit ``Timeline``.
public final class GnosticTimelineObject: CoatyObject {
    /// The timeline title.
    public var title: String

    /// Whether the timeline is archived.
    public var isArchived: Bool

    /// Whether the timeline is private.
    public var isPrivate: Bool

    /// The attached agent relationship, when present.
    public var attachedAgentID: UUID?

    /// The attached workspace relationships.
    public var attachedWorkspaceIDs: [UUID]

    /// The timeline creation timestamp.
    public var createdAt: Date

    /// The timeline's latest update timestamp.
    public var updatedAt: Date

    /// Registers Gnostic's canonical timeline object type.
    public override class var objectType: String {
        register(objectType: GnosticObjectType.timeline, with: self)
    }

    /// Creates a safe Axoloty projection of a timeline.
    ///
    /// - Parameter timeline: The PositronicKit timeline to expose on the network.
    public init(timeline: Timeline) {
        title = timeline.title
        isArchived = timeline.isArchived
        isPrivate = timeline.isPrivate
        attachedAgentID = timeline.attachedAgentInstanceId
        attachedWorkspaceIDs = timeline.attachedWorkspaceIds
        createdAt = timeline.createdAt
        updatedAt = timeline.updatedAt
        super.init(
            coreType: .CoatyObject,
            objectType: Self.objectType,
            objectId: CoatyUUID(uuidString: timeline.id.uuidString)!,
            name: timeline.title
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case isArchived
        case isPrivate
        case attachedAgentID
        case attachedWorkspaceIDs
        case createdAt
        case updatedAt
    }

    /// Decodes an advertised timeline projection.
    ///
    /// - Parameter decoder: The source decoder.
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        attachedAgentID = try container.decodeIfPresent(UUID.self, forKey: .attachedAgentID)
        attachedWorkspaceIDs = try container.decode([UUID].self, forKey: .attachedWorkspaceIDs)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        try super.init(from: decoder)
    }

    /// Encodes the safe timeline projection.
    ///
    /// - Parameter encoder: The destination encoder.
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encodeIfPresent(attachedAgentID, forKey: .attachedAgentID)
        try container.encode(attachedWorkspaceIDs, forKey: .attachedWorkspaceIDs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
