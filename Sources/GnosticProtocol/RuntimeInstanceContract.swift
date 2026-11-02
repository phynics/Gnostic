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
