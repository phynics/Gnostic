// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

extension GnosticTimelineObject {
    /// Creates a network projection from the Core's Timeline record.
    ///
    /// The memberwise initializer is
    /// ``init(id:title:attachedWorkspaceIDs:runtimeInstanceID:isArchived:isPrivate:createdAt:updatedAt:nodeID:protocolMajor:)``.
    public convenience init(
        timeline: RuntimeInstanceTimeline,
        nodeID: UUID? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.init(
            id: timeline.id,
            title: timeline.title,
            attachedWorkspaceIDs: timeline.attachedWorkspaceIDs,
            runtimeInstanceID: timeline.runtimeInstanceID,
            isArchived: timeline.isArchived,
            isPrivate: timeline.isPrivate,
            createdAt: timeline.createdAt,
            updatedAt: timeline.updatedAt,
            nodeID: nodeID,
            protocolMajor: protocolMajor
        )
    }
}
