// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A stable identifier for a narrative entry.
public struct NarrativeEntryID: Hashable, Codable, Sendable {
    /// The underlying UUID.
    public let rawValue: UUID

    /// Creates a new random stable identifier.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// The kind of long-horizon narrative an entry records.
public enum NarrativeEntryKind: String, Codable, Sendable {
    /// A single bounded episode within an arc.
    case episode
    /// A material change to an active arc.
    case arcUpdate
    /// A proposed reusable lesson.
    case lesson
    /// State about an open thread that must be reconstructed later.
    case openThread
    /// A proposed update to the operator's operational self-model.
    case operationalSelfModel
}

/// A stable, low-cardinality message range within a conversation.
public struct NarrativeConversationRange: Hashable, Codable, Sendable {
    /// The first message identifier in the range.
    public let firstMessageID: String
    /// The last message identifier in the range.
    public let lastMessageID: String

    /// Creates a conversation range.
    public init(firstMessageID: String, lastMessageID: String) {
        self.firstMessageID = firstMessageID
        self.lastMessageID = lastMessageID
    }

    /// An empty range describing a narrative not tied to explicit user messages.
    public static let empty = NarrativeConversationRange(
        firstMessageID: "",
        lastMessageID: ""
    )
}

/// Provenance for a narrative entry. Reference identifiers only; never embeds
/// Agent, Timeline, or Workspace object copies.
public struct NarrativeSourceReference: Hashable, Codable, Sendable {
    /// The source conversation message range.
    public let conversation: NarrativeConversationRange
    /// Tool identifiers involved.
    public let toolIDs: [String]
    /// Correlation identifiers involved.
    public let correlationIDs: [String]
    /// The contributing Gnostic agent identifier, if any.
    public let agentID: UUID?
    /// The contributing Gnostic timeline identifier, if any.
    public let timelineID: UUID?
    /// The contributing Gnostic workspace identifiers, if any.
    public let workspaceIDs: [UUID]
    /// The contributing task identifier, if any.
    public let taskID: String?
    /// File paths involved, if any.
    public let filePaths: [String]

    /// Creates a source reference.
    public init(
        conversation: NarrativeConversationRange,
        toolIDs: [String] = [],
        correlationIDs: [String] = [],
        agentID: UUID? = nil,
        timelineID: UUID? = nil,
        workspaceIDs: [UUID] = [],
        taskID: String? = nil,
        filePaths: [String] = []
    ) {
        self.conversation = conversation
        self.toolIDs = toolIDs
        self.correlationIDs = correlationIDs
        self.agentID = agentID
        self.timelineID = timelineID
        self.workspaceIDs = workspaceIDs
        self.taskID = taskID
        self.filePaths = filePaths
    }
}

/// A proposed, reusable lesson learned from one or more episodes.
public struct ProposedLesson: Hashable, Codable, Sendable {
    /// The lesson summary.
    public let summary: String

    /// Creates a proposed lesson.
    public init(summary: String) {
        self.summary = summary
    }
}

/// The liveness of an open thread.
public enum OpenThreadStatus: String, Codable, Sendable {
    /// The thread still needs attention.
    case active
    /// The thread has been resolved.
    case resolved
}

/// State describing an open thread to be reconstructed later.
public struct OpenThreadState: Hashable, Codable, Sendable {
    /// A short summary of the thread.
    public let summary: String
    /// Whether the thread is still active.
    public let status: OpenThreadStatus

    /// Creates open-thread state.
    public init(summary: String, status: OpenThreadStatus) {
        self.summary = summary
        self.status = status
    }
}

/// An immutable record of a long-horizon narrative event. Corrections append
/// a new entry that supersedes prior ones; stored entries are never mutated.
public struct NarrativeEntry: Hashable, Codable, Sendable {
    /// The stable identifier.
    public let id: NarrativeEntryID
    /// The kind of entry.
    public let kind: NarrativeEntryKind
    /// When the underlying event occurred.
    public let occurredAt: Date
    /// When the entry was recorded.
    public let recordedAt: Date
    /// Provenance references.
    public let source: NarrativeSourceReference
    /// The observed fact.
    public let observation: String
    /// The interpretation of the observation.
    public let interpretation: String
    /// A proposed reusable lesson, if this entry proposes one.
    public let lesson: ProposedLesson?
    /// Open-thread state, for entries of kind `.openThread`.
    public let openThread: OpenThreadState?
    /// The relative importance of this entry.
    public let importance: Double
    /// The confidence in this entry's interpretation.
    public let confidence: Double
    /// The identifiers of entries this entry supersedes.
    public let supersededIDs: [NarrativeEntryID]

    /// Creates an immutable narrative entry.
    public init(
        id: NarrativeEntryID,
        kind: NarrativeEntryKind,
        occurredAt: Date,
        recordedAt: Date,
        source: NarrativeSourceReference,
        observation: String,
        interpretation: String,
        lesson: ProposedLesson? = nil,
        openThread: OpenThreadState? = nil,
        importance: Double,
        confidence: Double,
        supersededIDs: [NarrativeEntryID]
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.source = source
        self.observation = observation
        self.interpretation = interpretation
        self.lesson = lesson
        self.openThread = openThread
        self.importance = importance
        self.confidence = confidence
        self.supersededIDs = supersededIDs
    }
}