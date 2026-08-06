// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A stable identifier for an immutable narrative page.
public struct NarrativePageID: Hashable, Codable, Sendable {
    /// The underlying UUID.
    public let rawValue: UUID

    /// Creates a new random page identifier.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// An immutable narrative image page.
///
/// A page freezes an older narrative summary into deterministic, immutable
/// rendered bytes plus a compact textual index. It records the stable source
/// entry identifiers and a content digest so existing pages are never
/// regenerated when new entries arrive. Exact active identifiers and values are
/// preserved textually rather than pixel-derived.
public struct NarrativePage: Hashable, Sendable {
    /// The stable page identifier.
    public let id: NarrativePageID
    /// The source narrative entry identifiers used to render this page.
    public let sourceEntryIDs: [NarrativeEntryID]
    /// A content digest over the rendered bytes.
    public let contentDigest: String
    /// The immutable rendered image bytes.
    public let renderedBytes: [UInt8]
    /// A compact textual index; a sufficient fallback when image loading fails.
    public let indexText: String
    /// The page title.
    public let title: String

    /// Creates an immutable narrative page.
    public init(
        id: NarrativePageID,
        sourceEntryIDs: [NarrativeEntryID],
        contentDigest: String,
        renderedBytes: [UInt8],
        indexText: String,
        title: String
    ) {
        self.id = id
        self.sourceEntryIDs = sourceEntryIDs
        self.contentDigest = contentDigest
        self.renderedBytes = renderedBytes
        self.indexText = indexText
        self.title = title
    }
}