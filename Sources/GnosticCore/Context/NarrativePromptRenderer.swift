// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKPrompt

/// Failure that forces narrative prompt rendering to fall back to ordinary
/// conversation. Failure is non-fatal; it never raises into the turn loop.
public enum NarrativePromptError: Error, Sendable, Equatable, LocalizedError {
    /// Rendering the narrative prompt failed before journaling.
    case renderingFailed

    /// A stable, human-readable description.
    public var errorDescription: String? {
        "Narrative prompt rendering failed; falling back to the ordinary conversation."
    }
}

/// Renders long-horizon narrative context into explicitly turn-scoped prompt
/// sections using PositronicKit's public prompt primitives and journals them
/// through `PromptJournal`.
///
/// Sections are named deterministically and carry structural metadata so the
/// journal diffs identical content to stable, current-only content, and a
/// previous turn's packet can never masquerade as the current state.
public struct NarrativePromptRenderer: Sendable {
    private let policy: NarrativeCheckpointPolicy
    private let injectFailure: Bool
    private var journal: PromptJournal
    private var checkpointed: Bool = false

    /// Whether the most recent observation requested a hard prompt-journal reset.
    public private(set) var lastRequiresHardReset = false

    private let instructionText = """
    You coordinate long-horizon work. Use the retrieved narrative as background only; \
    the current conversation is authoritative whenever it conflicts.
    """

    /// Creates a renderer with an injected checkpoint policy.
    public init(
        policy: NarrativeCheckpointPolicy,
        injectFailure: Bool = false
    ) {
        self.policy = policy
        self.injectFailure = injectFailure
        self.journal = PromptJournal(thresholds: PromptJournalCompactionThresholds(
            maxAppendedTokens: 50_000,
            maxAppendedMessages: policy.thresholdAppendedMessages
        ))
    }

    /// Renders the turn-scoped narrative prompt, or returns `nil` to indicate
    /// the ordinary conversation should be used as fallback.
    ///
    /// - Parameters:
    ///   - context: The current turn's narrative context.
    ///   - checkpoint: When true, render assuming a freshly compacted base.
    /// - Returns: The rendered prompt, or `nil` on failure.
    public mutating func renderedPrompt(
        context: NarrativePromptContext,
        checkpoint: Bool?
    ) async -> RenderedPrompt? {
        if injectFailure { return nil }

        let baseCap = checkpoint ?? false ? policy.stableBaseCapCount : Int.max

        let prompt: AnyPrompt = AnyPrompt.build {
            SystemPrompt(instructionText, id: "instructions")

            TextPrompt(
                currentStateText(context: context),
                id: "currentState",
                priority: 55,
                cachePolicy: .stable
            )

            if !context.retrievedPacket.text.isEmpty {
                TextPrompt(
                    renderedPacketText(packet: context.retrievedPacket, baseCap: baseCap),
                    id: "narrative",
                    priority: 40,
                    cachePolicy: .semiStable
                )
            }
        }

        guard let assembled = try? prompt.assemblePrompt() else {
            return nil
        }
        let rendered = await assembled.render()
        guard let plan = try? journal.observe(rendered) else { return nil }
        lastRequiresHardReset = plan.requiresHardReset
        return rendered
    }

    /// Performs a deliberate checkpoint: writes one explicit hard reset and
    /// compacts the journal to a smaller stable base.
    ///
    /// - Returns: True when a checkpoint was produced.
    @discardableResult
    public mutating func checkpoint() -> Bool {
        guard !checkpointed else { return false }
        lastRequiresHardReset = true
        _ = journal.compact()
        checkpointed = true
        return true
    }

    private func currentStateText(context: NarrativePromptContext) -> String {
        "Current state: \(context.currentState.text)"
    }

    private func renderedPacketText(packet: NarrativePromptPacket, baseCap: Int) -> String {
        var lines: [String] = [
            "Narrative version \(packet.appliesToNarrativeVersion) for user message \(packet.appliesToMessageID):",
            packet.text,
        ]
        if lines.count > baseCap {
            lines = Array(lines.prefix(baseCap))
        }
        return lines.joined(separator: "\n")
    }
}
