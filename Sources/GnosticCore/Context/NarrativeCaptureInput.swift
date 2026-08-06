// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The outcome of a bounded task, used to decide whether narrative capture is
/// warranted.
public enum NarrativeTaskOutcome: Sendable, Equatable {
    /// The bounded task completed successfully.
    case success
    /// The bounded task failed.
    case failure
}

/// Input describing a completed bounded task or a material arc change, passed
/// to `NarrativeProposer` for capture.
public struct NarrativeCaptureInput: Sendable, Equatable {
    /// The task identifier.
    public let taskID: String
    /// The task outcome.
    public let outcome: NarrativeTaskOutcome
    /// Whether the outcome affects later behavior.
    public let affectsLaterBehavior: Bool
    /// An open thread left behind, if any.
    public let openThread: OpenThreadState?
    /// Provenance references.
    public let source: NarrativeSourceReference

    /// Creates capture input.
    public init(
        taskID: String,
        outcome: NarrativeTaskOutcome,
        affectsLaterBehavior: Bool,
        openThread: OpenThreadState?,
        source: NarrativeSourceReference
    ) {
        self.taskID = taskID
        self.outcome = outcome
        self.affectsLaterBehavior = affectsLaterBehavior
        self.openThread = openThread
        self.source = source
    }

    /// Whether this input is materially relevant for narrative capture.
    public var isRelevant: Bool {
        affectsLaterBehavior || openThread != nil
    }
}

/// An async boundary that turns a completed bounded task into a narrative
/// proposal. The default determinism of a fixture proposer means tests need no
/// credentials or LLM.
public protocol NarrativeProposer: Sendable {
    /// Converts a completed task into a candidate proposal.
    ///
    /// - Parameter input: The completed task input.
    /// - Returns: A proposal, or `nil` when nothing narrative-worthy occurred.
    func propose(for input: NarrativeCaptureInput) async -> NarrativeProposal?

    /// Returns whether capture should proceed for the input. The default only
    /// records failed tool calls when they affect later behavior or leave open
    /// threads.
    func shouldRecordFailingCall(for input: NarrativeCaptureInput) -> Bool
}

extension NarrativeProposer {
    /// Failed tool calls create episodes only when they affect later behavior
    /// or leave open threads.
    public func shouldRecordFailingCall(for input: NarrativeCaptureInput) -> Bool {
        input.isRelevant
    }
}