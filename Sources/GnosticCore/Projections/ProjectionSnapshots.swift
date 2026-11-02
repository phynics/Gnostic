// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

// The immutable snapshots a consumer reads (issue #717, decision D29 on #551).
// Each is a value copy of the mutable transport object at the moment of the
// call, so the snapshot stays valid after the object changes.

extension GnosticRuntimeInstanceObject {
    /// An immutable copy of this Runtime instance's advertised fields.
    public var snapshot: RuntimeInstanceSnapshot {
        RuntimeInstanceSnapshot(
            id: runtimeInstanceID,
            name: name,
            protocolMajor: protocolMajor,
            nodeID: nodeID,
            runtimeKind: runtimeKind,
            runtimeVersion: runtimeVersion,
            launchFingerprint: launchFingerprint,
            health: health,
            rawCapabilities: rawCapabilities
        )
    }
}

extension GnosticTimelineObject {
    /// An immutable copy of this Timeline's advertised fields.
    public var snapshot: TimelineSnapshot {
        TimelineSnapshot(
            id: objectId.foundationUUID,
            protocolMajor: protocolMajor,
            title: title,
            isArchived: isArchived,
            isPrivate: isPrivate,
            runtimeInstanceID: runtimeInstanceID,
            attachedWorkspaceIDs: attachedWorkspaceIDs,
            nodeID: nodeID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension GnosticWorkspaceObject {
    /// An immutable copy of this Workspace's advertised fields.
    public var snapshot: NetworkWorkspaceDescriptor {
        NetworkWorkspaceDescriptor(
            id: objectId.foundationUUID,
            uri: uri,
            isAvailable: isAvailable,
            trustLevel: trustLevel,
            status: status,
            effectiveStatus: effectiveStatus,
            tools: tools,
            toolsComplete: toolsComplete,
            createdAt: createdAt
        )
    }
}

extension GnosticWorkspaceToolObject {
    /// An immutable copy of this Workspace tool's fields.
    public var snapshot: WorkspaceToolSnapshot {
        WorkspaceToolSnapshot(
            protocolMajor: protocolMajor,
            workspaceID: workspaceID,
            tool: tool,
            page: page,
            schemaTruncated: schemaTruncated
        )
    }
}
