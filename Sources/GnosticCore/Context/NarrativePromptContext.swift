// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A turn-scoped packet of retrieved narrative content that also names the exact
/// user-message identifier and narrative version it applies to.
public struct NarrativePromptPacket: Sendable, Equatable {
    /// The rendered narrative content.
    public let text: String
    /// The user-message identifier this packet applies to.
    public let appliesToMessageID: String
    /// The narrative version this packet was rendered against.
    public let appliesToNarrativeVersion: Int

    /// Creates a turn-scoped narrative packet.
    public init(text: String, appliesToMessageID: String, appliesToNarrativeVersion: Int) {
        self.text = text
        self.appliesToMessageID = appliesToMessageID
        self.appliesToNarrativeVersion = appliesToNarrativeVersion
    }

    /// Whether this packet is current for the given user message and version.
    public func applies(to messageID: String, version: Int) -> Bool {
        appliesToMessageID == messageID && appliesToNarrativeVersion == version
    }
}

/// Context for rendering the turn-scoped narrative prompt.
public struct NarrativePromptContext: Sendable {
    /// The current user-message identifier.
    public let userMessageID: String
    /// The current narrative version.
    public let narrativeVersion: Int
    /// The retrieved narrative packet relevant to this turn.
    public let retrievedPacket: NarrativePromptPacket
    /// The authoritative current conversation state.
    public let currentState: CurrentStatePacket

    /// Creates a rendering context.
    public init(
        userMessageID: String,
        narrativeVersion: Int,
        retrievedPacket: NarrativePromptPacket,
        currentState: CurrentStatePacket
    ) {
        self.userMessageID = userMessageID
        self.narrativeVersion = narrativeVersion
        self.retrievedPacket = retrievedPacket
        self.currentState = currentState
    }
}