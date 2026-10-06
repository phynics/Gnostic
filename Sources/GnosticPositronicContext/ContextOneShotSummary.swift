// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Baseline 3: a single-pass summary of the whole history.
///
/// The offline gate cannot call a live summarizer, so this baseline is a
/// deterministic stand-in: it keeps a fixed head window and a fixed tail
/// window and drops everything between. It is deliberately obligation-blind,
/// which is what makes it a fair baseline for the structured curator rather
/// than a straw man.
///
/// A live LLM one-shot summary is a recorded follow-up, not part of the
/// offline gate.
public enum ContextOneShotSummary {
    /// The number of leading turns the summary keeps.
    public static let headTurns = 4
    /// The number of trailing turns the summary keeps.
    public static let tailTurns = 12

    /// Renders the transcript as a single head-plus-tail summary.
    ///
    /// - Parameter transcript: The history to summarize.
    /// - Returns: The summary as plain text.
    public static func project(_ transcript: ContextTranscript) -> String {
        let turns = transcript.turns
        guard turns.count > headTurns + tailTurns else { return transcript.rendered }
        let kept = Array(turns.prefix(headTurns)) + Array(turns.suffix(tailTurns))
        return kept.map(\.text).joined(separator: "\n")
    }
}
