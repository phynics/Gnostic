// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A candidate narrative record with structured fields ready for validation.
///
/// A proposal is not persistable directly: it must first pass
/// `NarrativeValidator.validate(_:against:)` to become an admitted
/// `NarrativeEntry`. Proposals may carry speculative or over-broad claims that
/// validation must flag and reject.
public struct NarrativeProposal: Hashable, Sendable {
    /// The candidate stable identifier, matched against the store for duplicates.
    public var id: NarrativeEntryID
    /// The proposed entry kind.
    public var kind: NarrativeEntryKind
    /// When the underlying event occurred.
    public var occurredAt: Date
    /// Provenance references.
    public var source: NarrativeSourceReference
    /// The observed fact.
    public var observation: String
    /// The proposed interpretation.
    public var interpretation: String
    /// A proposed reusable lesson, if this proposal offers one.
    public var lesson: ProposedLesson?
    /// Open-thread state, for proposals of kind `.openThread`.
    public var openThread: OpenThreadState?
    /// The proposed importance.
    public var importance: Double
    /// The proposed confidence.
    public var confidence: Double
    /// Identifiers of prior episodes supporting this proposal.
    public var supportingEpisodes: [NarrativeEntryID]
    /// Whether the observation states speculation as fact.
    public var isFactStatedSpeculation: Bool
    /// Whether the proposal makes an over-broad self-characterization.
    public var isOverbroadSelfCharacterization: Bool

    /// Creates a proposal.
    public init(
        id: NarrativeEntryID,
        kind: NarrativeEntryKind,
        occurredAt: Date,
        source: NarrativeSourceReference,
        observation: String,
        interpretation: String,
        lesson: ProposedLesson? = nil,
        openThread: OpenThreadState? = nil,
        importance: Double,
        confidence: Double,
        supportingEpisodes: [NarrativeEntryID],
        isFactStatedSpeculation: Bool,
        isOverbroadSelfCharacterization: Bool
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.source = source
        self.observation = observation
        self.interpretation = interpretation
        self.lesson = lesson
        self.openThread = openThread
        self.importance = importance
        self.confidence = confidence
        self.supportingEpisodes = supportingEpisodes
        self.isFactStatedSpeculation = isFactStatedSpeculation
        self.isOverbroadSelfCharacterization = isOverbroadSelfCharacterization
    }
}

/// The authoritative orchestration state a validator consults without copying
/// it into the narrative.
public struct NarrativeAuthoritativeState: Sendable {
    /// The current agent identifier.
    public var agentID: UUID?
    /// The current timeline identifiers.
    public var timelineIDs: [UUID]
    /// The current attached workspace identifiers.
    public var workspaceIDs: [UUID]
    /// Relevant file paths known to the current turn.
    public var filePaths: [String]
    /// Values sourced from metadata that must never enter the narrative.
    public var unsafeMetadataValues: [String]

    /// Creates authoritative state.
    public init(
        agentID: UUID? = nil,
        timelineIDs: [UUID] = [],
        workspaceIDs: [UUID] = [],
        filePaths: [String] = [],
        unsafeMetadataValues: [String] = []
    ) {
        self.agentID = agentID
        self.timelineIDs = timelineIDs
        self.workspaceIDs = workspaceIDs
        self.filePaths = filePaths
        self.unsafeMetadataValues = unsafeMetadataValues
    }
}