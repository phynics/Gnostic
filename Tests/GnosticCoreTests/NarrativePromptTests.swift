// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PositronicKit
import Testing

@Suite("Narrative turn-scoped prompts and checkpoints")
struct NarrativePromptTests {
    private func context(messageID: String = "msg-101", version: Int = 3) -> NarrativePromptContext {
        NarrativePromptContext(
            userMessageID: messageID,
            narrativeVersion: version,
            retrievedPacket: NarrativePromptPacket(
                text: "Subject arc: parameter schema note.",
                appliesToMessageID: messageID,
                appliesToNarrativeVersion: version
            ),
            currentState: CurrentStatePacket(
                authorativeState: "current conversation overrides narrative",
                isAuthoritative: true
            )
        )
    }

    private func packet(
        text: String = "content",
        messageID: String = "msg-101",
        version: Int = 3
    ) -> NarrativePromptPacket {
        NarrativePromptPacket(
            text: text,
            appliesToMessageID: messageID,
            appliesToNarrativeVersion: version
        )
    }

    @Test("stable instructions stay stable across a normal append")
    func stableInstructionsStayStableAcrossNormalAppend() async throws {
        var renderer = NarrativePromptRenderer(policy: NarrativeCheckpointPolicy.default)
        let first = try #require(await renderer.renderedPrompt(context: context(), checkpoint: nil))
        let second = try #require(await renderer.renderedPrompt(context: context(), checkpoint: nil))

        #expect(first.sectionsByID["instructions"] == second.sectionsByID["instructions"])
        #expect(renderer.lastRequiresHardReset == false)
    }

    @Test("every retrieved packet names the user-message id and narrative version")
    func everyPacketNamesMessageIDAndVersion() {
        let p = packet(messageID: "msg-101", version: 7)
        #expect(p.appliesToMessageID == "msg-101")
        #expect(p.appliesToNarrativeVersion == 7)
        #expect(p.applies(to: "msg-101", version: 7) == true)
    }

    @Test("older turn packets remain historical and cannot masquerade as current")
    func olderTurnPacketsRemainHistorical() {
        let older = packet(messageID: "msg-90", version: 1)
        #expect(older.applies(to: "msg-101", version: 3) == false)
    }

    @Test("current user corrections override narrative in rendered precedence")
    func userCorrectionsOverrideNarrative() async throws {
        var renderer = NarrativePromptRenderer(policy: NarrativeCheckpointPolicy.default)
        let rendered = try #require(await renderer.renderedPrompt(context: context(), checkpoint: nil))
        let currentStateText = rendered.sectionsByID["currentState"] ?? ""
        #expect(currentStateText.contains("current conversation overrides narrative"))
    }

    @Test("normal appends do not request a hard prompt-journal reset")
    func normalAppendsDoNotRequestHardReset() async throws {
        var renderer = NarrativePromptRenderer(policy: NarrativeCheckpointPolicy.default)
        _ = try #require(await renderer.renderedPrompt(context: context(), checkpoint: nil))
        _ = try #require(await renderer.renderedPrompt(context: context(), checkpoint: nil))
        #expect(renderer.lastRequiresHardReset == false)
    }

    @Test("a deliberate checkpoint produces one explicit reset and a smaller stable base")
    func deliberateCheckpointProducesExplicitReset() async throws {
        var renderer = NarrativePromptRenderer(policy: NarrativeCheckpointPolicy(
            thresholdAppendedMessages: 2,
            stableBaseCapCount: 3
        ))
        _ = try #require(await renderer.renderedPrompt(context: context(), checkpoint: nil))
        _ = try #require(await renderer.renderedPrompt(context: context(), checkpoint: nil))

        let didReset = renderer.checkpoint()
        #expect(didReset == true)

        let after = try #require(await renderer.renderedPrompt(context: context(), checkpoint: true))
        #expect(after.sections.count <= 3)
    }

    @Test("prompt rendering failure falls back to ordinary conversation")
    func renderingFailureFallsBackToOrdinary() async throws {
        var renderer = NarrativePromptRenderer(
            policy: NarrativeCheckpointPolicy.default,
            injectFailure: true
        )
        let rendered = await renderer.renderedPrompt(context: context(), checkpoint: nil)
        #expect(rendered == nil)
    }
}