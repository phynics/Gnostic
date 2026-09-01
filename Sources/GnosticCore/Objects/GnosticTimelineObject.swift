// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// A safe network projection of a Gnostic Timeline.
public final class GnosticTimelineObject: CoatyObject, @unchecked Sendable {
    /// The protocol major carried by this advertisement.
    public let protocolMajor: Int

    /// The timeline title.
    public var title: String

    /// Whether the timeline is archived.
    public var isArchived: Bool

    /// Whether the timeline is private.
    public var isPrivate: Bool

    /// The attached Ascendant relationship, when present.
    public var attachedAscendantID: UUID?

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

    /// Creates a network projection without exposing a provider's Timeline type.
    public init(timeline: AscendantRuntimeTimeline, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        title = GnosticWirePayload.boundedLabel(timeline.title)
        isArchived = timeline.isArchived
        isPrivate = timeline.isPrivate
        attachedAscendantID = timeline.ascendantID
        attachedWorkspaceIDs = GnosticWirePayload.boundedWorkspaceIDs(timeline.attachedWorkspaceIDs)
        createdAt = timeline.createdAt
        updatedAt = timeline.updatedAt
        super.init(
            coreType: .CoatyObject,
            objectType: Self.objectType,
            objectId: CoatyUUID(uuidString: timeline.id.uuidString)!,
            name: GnosticWirePayload.boundedLabel(timeline.title)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case protocolMajor
        case isArchived
        case isPrivate
        case attachedAscendantID
        case attachedWorkspaceIDs
        case createdAt
        case updatedAt
    }

    /// Decodes an advertised timeline projection.
    ///
    /// - Parameter decoder: The source decoder.
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        title = GnosticWirePayload.boundedLabel(try container.decode(String.self, forKey: .title))
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        attachedAscendantID = try container.decodeIfPresent(UUID.self, forKey: .attachedAscendantID)
        attachedWorkspaceIDs = GnosticWirePayload.boundedWorkspaceIDs(try container.decode([UUID].self, forKey: .attachedWorkspaceIDs))
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
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(title, forKey: .title)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encodeIfPresent(attachedAscendantID, forKey: .attachedAscendantID)
        try container.encode(attachedWorkspaceIDs, forKey: .attachedWorkspaceIDs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
