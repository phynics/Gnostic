// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The wire payload requesting timeline state.
public struct TimelineStatusRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID

    public init(timelineID: UUID, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
    }
}

/// The wire result describing a timeline's attachment state.
public struct TimelineStatus: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let title: String
    public let attachedWorkspaceIDs: [UUID]
    public let isArchived: Bool
    public let isPrivate: Bool

    public init(
        timelineID: UUID,
        title: String,
        attachedWorkspaceIDs: [UUID],
        isArchived: Bool = false,
        isPrivate: Bool = false,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.title = GnosticWirePayload.boundedLabel(title)
        self.attachedWorkspaceIDs = GnosticWirePayload.boundedWorkspaceIDs(attachedWorkspaceIDs)
        self.isArchived = isArchived
        self.isPrivate = isPrivate
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, title, attachedWorkspaceIDs, isArchived, isPrivate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        title = GnosticWirePayload.boundedLabel(try container.decode(String.self, forKey: .title))
        attachedWorkspaceIDs = GnosticWirePayload.boundedWorkspaceIDs(try container.decode([UUID].self, forKey: .attachedWorkspaceIDs))
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
    }
}
