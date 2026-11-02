// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Stable interoperability behaviors a remote client may select by name.
/// Backend kind and version are intentionally not capabilities.
public enum InteroperabilityCapability: String, Codable, Sendable, Equatable, CaseIterable {
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
    /// Reading payload-free live runtime diagnostics from the serving Node.
    case diagnostics = "me.atkn.gnostic.capability.diagnostics"
}

/// The capabilities a Runtime instance offers to remote clients.
///
/// `interoperability` is a `Set<String>` rather than a set of
/// ``InteroperabilityCapability`` on purpose: capability IDs are
/// negotiated with peers that may run a newer build, so a value this build
/// does not know must survive a round trip rather than be dropped.
public struct RuntimeInstanceCapabilities: Codable, Sendable, Equatable {
    /// Interoperability capability IDs, as raw ``InteroperabilityCapability`` values.
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

/// The stable identity projection owned by Gnostic for one Runtime instance.
///
/// A backend may use a provider-native identity internally, but that identity
/// must never become part of the Gnostic host contract.
public struct RuntimeInstanceIdentity: Sendable, Equatable {
    /// The Gnostic-owned Runtime instance identifier.
    public let id: UUID
    /// The Runtime instance's display name.
    public let name: String
    /// The Runtime instance's description.
    public let description: String
    /// The Timeline the Runtime instance operates privately.
    public let privateTimelineID: UUID
    /// The Workspace bound to the Runtime instance by default, if any.
    public let primaryWorkspaceID: UUID?
    /// When the Runtime instance last served a Turn.
    public let lastActiveAt: Date
    /// When Gnostic created the Runtime instance.
    public let createdAt: Date
    /// When the Runtime instance's projection last changed.
    public let updatedAt: Date
    /// What the Runtime instance offers.
    public let capabilities: RuntimeInstanceCapabilities

    /// Creates the Gnostic-owned identity projection for one Runtime instance.
    public init(
        id: UUID,
        name: String,
        description: String,
        privateTimelineID: UUID,
        primaryWorkspaceID: UUID?,
        lastActiveAt: Date,
        createdAt: Date,
        updatedAt: Date,
        capabilities: RuntimeInstanceCapabilities = .empty
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
public struct RuntimeInstanceTimeline: Sendable, Equatable {
    /// The Gnostic-owned Timeline identifier.
    public let id: UUID
    /// The Timeline's title.
    public let title: String
    /// Workspaces currently attached to the Timeline.
    public let attachedWorkspaceIDs: [UUID]
    /// The Runtime instance operating the Timeline, if any.
    public let runtimeInstanceID: UUID?
    /// Whether the Timeline is archived.
    public let isArchived: Bool
    /// Whether the Timeline is the operating Runtime instance's private Timeline.
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
        runtimeInstanceID: UUID?,
        isArchived: Bool,
        isPrivate: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.runtimeInstanceID = runtimeInstanceID
        self.isArchived = isArchived
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
