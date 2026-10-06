// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKPrompt

/// Baseline 2: the current PositronicKit prompt-budget behavior.
///
/// It builds one `StructuredCompressionNode` per history turn and runs the
/// public `StructuredCompressionPlanner` against a deliberately small token
/// budget, so the long-horizon transcript overflows exactly as it would in a
/// small context window. The planner keeps, truncates, summarizes, or drops
/// each turn; this type renders the resulting plan back to plain text in
/// chronological order.
///
/// The baseline models the *mechanism* (a token budget with no obligation
/// awareness), not a live provider call. It contacts nothing.
public enum ContextPKCompression {
    /// The default budget, small enough that the fixture transcript overflows.
    public static let defaultBudgetTokens = 64

    /// Renders the transcript through the PositronicKit compression planner.
    ///
    /// - Parameters:
    ///   - transcript: The history to compress.
    ///   - budgetTokens: The token budget for the whole history.
    /// - Returns: The compressed history as plain text.
    /// - Throws: A `PromptCompressionError` when the planner rejects the nodes.
    public static func project(_ transcript: ContextTranscript, budgetTokens: Int = defaultBudgetTokens) throws -> String {
        let nodes = transcript.turns.map { turn in
            StructuredCompressionNode(
                id: ContextHashing.pathComponent(turn.index),
                path: ["history", ContextHashing.pathComponent(turn.index)],
                nodeHash: ContextHashing.fnv1a(turn.text),
                priority: priority(for: turn.role),
                cachePolicy: .volatile,
                strategy: .truncate(keeping: .head),
                estimatedTokens: estimatedTokens(turn.text)
            )
        }
        let plan = try StructuredCompressionPlanner().plan(nodes: nodes, availableTokens: budgetTokens, diff: nil)
        let byID = Dictionary(uniqueKeysWithValues: transcript.turns.map { (ContextHashing.pathComponent($0.index), $0) })
        var rendered: [String] = []
        for action in plan.nodeActions {
            guard let turn = byID[action.nodeID] else { continue }
            switch action.action {
            case .keep:
                rendered.append(turn.text)
            case let .truncate(limit, retention):
                rendered.append(truncate(turn.text, toTokens: limit, keepHead: retention == .head))
            case let .summarize(targetTokens, _):
                rendered.append(truncate(turn.text, toTokens: targetTokens, keepHead: true))
            case .drop:
                break
            }
        }
        return rendered.joined(separator: "\n")
    }

    private static func priority(for role: ContextTurnRole) -> Int {
        switch role {
        case .assistant: 80
        case .tool: 60
        case .user: 50
        }
    }

    private static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private static func truncate(_ text: String, toTokens tokens: Int, keepHead: Bool) -> String {
        let characterLimit = max(1, tokens * 4)
        guard text.count > characterLimit else { return text }
        return keepHead ? String(text.prefix(characterLimit)) : String(text.suffix(characterLimit))
    }
}
