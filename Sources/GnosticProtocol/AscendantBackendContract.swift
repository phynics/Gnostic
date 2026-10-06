// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Stable interoperability behaviors a remote client may select by name.
/// Backend kind and version are intentionally not capabilities.
public enum AscendantInteroperabilityCapability: String, Codable, Sendable, Equatable, CaseIterable {
    /// A plain text prompt and reply.
    case textTurn = "me.atkn.gnostic.capability.turn.text"
    /// Incremental updates streamed while a Turn runs.
    case streamedUpdates = "me.atkn.gnostic.capability.turn.stream"
    /// In-flight cancellation of a running Turn.
    case cancellation = "me.atkn.gnostic.capability.turn.cancel"
    /// Replay of a completed Turn's bounded update stream.
    case replay = "me.atkn.gnostic.capability.turn.replay"
    /// Host-mediated approval for tool calls that require it.
    case permissionMediation = "me.atkn.gnostic.capability.permission.mediation"
    /// Creating and renaming Timelines through the existing lifecycle operations.
    case timelineManagement = "me.atkn.gnostic.capability.timeline.management"
    /// Attaching a Workspace to a Timeline.
    case workspaceAttachment = "me.atkn.gnostic.capability.workspace.attach"
    /// Invoking a tool advertised by an attached Workspace.
    case workspaceToolInvocation = "me.atkn.gnostic.capability.workspace.tool"
}

/// Runtime health of an Ascendant's bound backend.
///
/// Health is deliberately separate from routability: a failed backend keeps
/// its Gnostic-owned Ascendant and Timeline relationships available for a
/// bounded reconstruction attempt.
public enum AscendantBackendHealth: String, Codable, Sendable, Equatable {
    /// The backend is bound and serving its Ascendant.
    case healthy
    /// The backend can no longer serve; reconstruction may be attempted.
    case failed
    /// No health has been observed yet.
    case unknown
}

/// The capabilities an Ascendant advertises to remote clients.
///
/// `interoperability` is a `Set<String>` rather than a set of
/// ``AscendantInteroperabilityCapability`` on purpose: capability IDs are
/// negotiated with peers that may run a newer build, so a value this build
/// does not know must survive a round trip rather than be dropped.
public struct AscendantBackendCapabilities: Codable, Sendable, Equatable {
    /// Interoperability capability IDs, as raw ``AscendantInteroperabilityCapability`` values.
    public let interoperability: Set<String>
    /// Host-defined capability IDs that are not part of the interoperability contract.
    public let host: Set<String>
    /// The backend implementation's kind, for diagnostics only. Never routed on.
    public let backendKind: String?
    /// The backend implementation's version, for diagnostics only.
    public let backendVersion: String?

    /// Creates a capability set. Every field is optional.
    public init(
        interoperability: Set<String> = [],
        host: Set<String> = [],
        backendKind: String? = nil,
        backendVersion: String? = nil
    ) {
        self.interoperability = interoperability
        self.host = host
        self.backendKind = backendKind
        self.backendVersion = backendVersion
    }

    /// A capability set advertising nothing.
    public static var empty: Self { .init() }
}

/// The stable identity projection owned by Gnostic for one Ascendant.
///
/// A backend may use a provider-native identity internally, but that identity
/// must never become part of the Gnostic host contract.
public struct AscendantBackendIdentity: Sendable, Equatable {
    /// The Gnostic-owned Ascendant identifier.
    public let id: UUID
    /// The Ascendant's display name.
    public let name: String
    /// The Ascendant's description.
    public let description: String
    /// The Timeline the Ascendant operates privately.
    public let privateTimelineID: UUID
    /// The Workspace bound to the Ascendant by default, if any.
    public let primaryWorkspaceID: UUID?
    /// When the Ascendant last served a Turn.
    public let lastActiveAt: Date
    /// When Gnostic created the Ascendant.
    public let createdAt: Date
    /// When the Ascendant's projection last changed.
    public let updatedAt: Date
    /// What the Ascendant advertises it can do.
    public let capabilities: AscendantBackendCapabilities

    /// Creates the Gnostic-owned identity projection for one Ascendant.
    public init(
        id: UUID,
        name: String,
        description: String,
        privateTimelineID: UUID,
        primaryWorkspaceID: UUID?,
        lastActiveAt: Date,
        createdAt: Date,
        updatedAt: Date,
        capabilities: AscendantBackendCapabilities = .empty
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.privateTimelineID = privateTimelineID
        self.primaryWorkspaceID = primaryWorkspaceID
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.capabilities = capabilities
    }

}

/// The backend's private projection of a Gnostic Timeline.
public struct AscendantBackendTimeline: Sendable, Equatable {
    /// The Gnostic-owned Timeline identifier.
    public let id: UUID
    /// The Timeline's title.
    public let title: String
    /// Workspaces currently attached to the Timeline.
    public let attachedWorkspaceIDs: [UUID]
    /// The Ascendant operating the Timeline, if any.
    public let ascendantID: UUID?
    /// Whether the Timeline is archived.
    public let isArchived: Bool
    /// Whether the Timeline is the operating Ascendant's private Timeline.
    public let isPrivate: Bool
    /// When Gnostic created the Timeline.
    public let createdAt: Date
    /// When the Timeline last changed.
    public let updatedAt: Date

    /// Creates a backend's projection of one Gnostic Timeline.
    public init(
        id: UUID,
        title: String,
        attachedWorkspaceIDs: [UUID],
        ascendantID: UUID?,
        isArchived: Bool,
        isPrivate: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.ascendantID = ascendantID
        self.isArchived = isArchived
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Compatibility initializer for the pre-reset projection spelling.
    public init(
        id: UUID,
        title: String,
        attachedWorkspaceIDs: [UUID],
        attachedAscendantID: UUID?,
        isArchived: Bool,
        isPrivate: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.init(
            id: id,
            title: title,
            attachedWorkspaceIDs: attachedWorkspaceIDs,
            ascendantID: attachedAscendantID,
            isArchived: isArchived,
            isPrivate: isPrivate,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// The pre-reset spelling of ``ascendantID``.
    public var attachedAscendantID: UUID? { ascendantID }
}
