// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Structured failures for the semantic context compiler experiment.
///
/// The experiment target keeps its own error vocabulary so it stays free of
/// backend and kit error types. Every case is a value a test can assert on.
public enum ContextError: Error, Equatable, CustomStringConvertible {
    /// A curator response was not the proposal shape the descriptor requires.
    case malformedProposal(String)
    /// A proposal cited a source range that is not in the replayed episode.
    case unknownSourceRange(String)
    /// A proposal mixed Ascendants or Timelines.
    case crossTimeline(String)
    /// Two nodes share an identity but not a body.
    case conflictingBody(id: String)
    /// A proposal asked for more than the descriptor allows.
    case budgetExceeded(String)
    /// A proposal was made against a different descriptor version.
    case descriptorMismatch(String)
    /// A citation did not match the role ceiling the descriptor sets.
    case invalidCitation(String)
    /// The carry reduction could not cover the hierarchy exactly once.
    case coverageGap(String)

    public var description: String {
        switch self {
        case let .malformedProposal(reason):
            "the curator proposal is malformed: \(reason)"
        case let .unknownSourceRange(reference):
            "the proposal cites an unknown source range '\(reference)'"
        case let .crossTimeline(reason):
            "the proposal crosses an Ascendant or Timeline boundary: \(reason)"
        case let .conflictingBody(id):
            "node '\(id)' already exists with a different body"
        case let .budgetExceeded(reason):
            "the proposal exceeds the descriptor budget: \(reason)"
        case let .descriptorMismatch(reason):
            "the proposal does not match the active descriptor: \(reason)"
        case let .invalidCitation(reason):
            "the proposal citation is not allowed: \(reason)"
        case let .coverageGap(reason):
            "the carry reduction does not cover the hierarchy exactly once: \(reason)"
        }
    }
}
