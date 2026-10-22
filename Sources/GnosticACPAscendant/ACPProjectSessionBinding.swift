// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// The observable binding between one Gnostic Timeline and its ACP Session.
///
/// A new binding is created when the effective Project `cwd` changes. It does
/// not imply that model reasoning or Runtime context continued from an earlier
/// Session.
public struct ACPProjectSessionBinding: Equatable, Sendable {
    /// The Gnostic Timeline that owns the Session.
    public let timelineID: UUID
    /// The ACP Runtime's Session identifier.
    public let sessionID: String
    /// The exact `cwd` used when the Session was created.
    public let cwd: String
    /// The Project placement used for the Session.
    public let projectKind: Project.Kind
    /// When the Session binding was created or last transitioned.
    public let startedAt: Date
    /// Whether Gnostic can guarantee model-context continuity from a prior
    /// Session. A Project transition always reports `false`.
    public var contextContinuityGuaranteed: Bool { false }
}
