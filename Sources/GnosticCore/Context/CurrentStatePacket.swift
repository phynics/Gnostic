// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A textual packet describing the authoritative current orchestration state.
///
/// Exact UUIDs, paths, timestamps, approvals, attachments, and blockers remain
/// textual. When `isAuthoritative` is true, this packet explicitly outranks any
/// conflicting narrative interpretation for the current turn.
public struct CurrentStatePacket: Sendable, Equatable {
    /// The textual current-state description.
    public let text: String
    /// Whether this describes the authoritative current state and therefore
    /// outranks conflicting narrative interpretation.
    public let isAuthoritative: Bool

    /// Creates a current-state packet.
    ///
    /// - Parameters:
    ///   - authorativeState: The textual current-state description. The
    ///     misspelled label is kept for API compatibility.
    ///   - isAuthoritative: Whether this is the authoritative current state.
    public init(authorativeState: String, isAuthoritative: Bool) {
        self.text = authorativeState
        self.isAuthoritative = isAuthoritative
    }
}