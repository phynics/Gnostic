// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// An immutable snapshot of a Timeline as its Node advertised it.
///
/// It is a value: a consumer can pass it between actors without
/// synchronization. Read it from ``NetworkCatalogEntry/timeline``.
public struct TimelineSnapshot: Sendable, Equatable {
    /// The Timeline identifier.
    public let id: UUID

    /// The protocol major the advertisement carries.
    public let protocolMajor: Int

    /// The Timeline title, truncated to the label bound.
    public let title: String

    /// Whether the Timeline is archived.
    public let isArchived: Bool

    /// Whether the Timeline is private.
    public let isPrivate: Bool

    /// The Runtime instance that operates the Timeline, when one does.
    public let runtimeInstanceID: UUID?

    /// The Workspaces attached to the Timeline.
    public let attachedWorkspaceIDs: [UUID]

    /// The identity of the Node that serves the Timeline. It is absent on an
    /// advertisement from a Node older than this property.
    public let nodeID: UUID?

    /// When Gnostic created the Timeline.
    public let createdAt: Date

    /// When the Timeline last changed.
    public let updatedAt: Date

    /// The Timeline's status, in the shape the Timeline client returns.
    public var status: TimelineStatus {
        TimelineStatus(
            timelineID: id,
            title: title,
            attachedWorkspaceIDs: attachedWorkspaceIDs,
            isArchived: isArchived,
            isPrivate: isPrivate,
            protocolMajor: protocolMajor
        )
    }

    /// Creates a Timeline snapshot.
    public init(
        id: UUID,
        protocolMajor: Int = GnosticProtocol.currentMajor,
        title: String,
        isArchived: Bool = false,
        isPrivate: Bool = false,
        runtimeInstanceID: UUID? = nil,
        attachedWorkspaceIDs: [UUID] = [],
        nodeID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.protocolMajor = protocolMajor
        self.title = title
        self.isArchived = isArchived
        self.isPrivate = isPrivate
        self.runtimeInstanceID = runtimeInstanceID
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.nodeID = nodeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
