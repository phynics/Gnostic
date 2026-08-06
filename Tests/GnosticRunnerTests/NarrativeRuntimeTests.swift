// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticRunner

@Suite("Narrative runtime")
struct NarrativeRuntimeTests {
    @Test("default runtime wires a working capture path") @MainActor
    func defaultRuntimeWiresCapture() async throws {
        let runtime = NarrativeRuntime()

        let outcome = await runtime.capture.capture(input: NarrativeCaptureInput(
            taskID: "unit",
            outcome: .success,
            affectsLaterBehavior: true,
            openThread: nil,
            source: NarrativeSourceReference(
                conversation: NarrativeConversationRange(firstMessageID: "u-1", lastMessageID: "u-2"),
                toolIDs: ["tool-a"],
                workspaceIDs: []
            )
        ))

        #expect(outcome.recorded == true)
        // The deterministic FixtureProposer yields a lesson; the store now holds it.
        await runtime.shutdown()
    }

    @Test("shutdown flushes in-flight capture work") @MainActor
    func shutdownFlushes() async throws {
        let store = InMemoryNarrativeStore()
        let runtime = NarrativeRuntime(store: store, proposer: FixtureNarrativeProposer())
        let input = NarrativeCaptureInput(
            taskID: "flush",
            outcome: .success,
            affectsLaterBehavior: true,
            openThread: nil,
            source: NarrativeSourceReference(
                conversation: NarrativeConversationRange(firstMessageID: "f-1", lastMessageID: "f-2"),
                toolIDs: [],
                workspaceIDs: []
            )
        )

        // Fire an async capture and immediately shut down; shutdown must wait
        // for pending work so the entry is stored when it returns.
        let captureTask = Task { await runtime.capture.capture(input: input) }
        await runtime.shutdown()
        let outcome = await captureTask.value

        #expect(outcome.recorded == true)
        #expect(await store.snapshot().count == 1)
    }
}

/// A minimal proposer for the shutdown test.
struct FixtureNarrativeProposer: NarrativeProposer {
    func propose(for input: NarrativeCaptureInput) async -> NarrativeProposal? {
        NarrativeProposal(
            id: NarrativeEntryID(),
            kind: .lesson,
            occurredAt: Date(),
            source: input.source,
            observation: "A bounded task completed.",
            interpretation: "Reusable outcome captured.",
            lesson: ProposedLesson(summary: "Reuse earlier outcomes."),
            importance: 0.6,
            confidence: 0.8,
            supportingEpisodes: [],
            isFactStatedSpeculation: false,
            isOverbroadSelfCharacterization: false
        )
    }
}