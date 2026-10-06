// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Structured failures for the semantic context compiler experiment.
///
/// The experiment target keeps its own error vocabulary so it stays free of
/// backend and kit error types. Every case is a value a test can assert on.
///
/// The cases carry no payload. A diagnostic never echoes conversation text,
/// a model response, or a node body, so an error cannot leak content.
public enum ContextError: Error, Equatable, CustomStringConvertible {
    /// A curator response was not the proposal shape the descriptor requires.
    case malformedProposal
    /// A proposal cited a source range that is not in the replayed episode.
    case unknownSourceRange
    /// A proposal mixed Ascendants or Timelines.
    case crossTimeline
    /// Two nodes share an identity but not a body.
    case conflictingBody
    /// A proposal asked for more than the descriptor allows.
    case budgetExceeded
    /// A proposal was made against a different descriptor version.
    case descriptorMismatch
    /// A citation did not match the role ceiling the descriptor sets.
    case invalidCitation
    /// The carry reduction could not cover the hierarchy exactly once.
    case coverageGap
    /// A checkpoint cut fell between an assistant tool call and its tool result.
    case toolTransactionSplit
    /// A checkpoint lost a carry item the deterministic reduction requires.
    case carrySurvivalFailed

    /// A payload-free human-readable description.
    public var description: String {
        switch self {
        case .malformedProposal:
            "the curator proposal is malformed"
        case .unknownSourceRange:
            "the proposal cites an unknown source range"
        case .crossTimeline:
            "the proposal crosses an Ascendant or Timeline boundary"
        case .conflictingBody:
            "a node already exists with a different body"
        case .budgetExceeded:
            "the proposal exceeds the descriptor budget"
        case .descriptorMismatch:
            "the proposal does not match the active descriptor"
        case .invalidCitation:
            "the proposal citation is not allowed"
        case .coverageGap:
            "the carry reduction does not cover the hierarchy exactly once"
        case .toolTransactionSplit:
            "the checkpoint cut splits a tool transaction"
        case .carrySurvivalFailed:
            "the checkpoint carry is missing a required item"
        }
    }
}
