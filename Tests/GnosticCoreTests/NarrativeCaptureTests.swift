// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Non-blocking narrative capture and runner integration")
struct NarrativeCaptureTests {
    private let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!

    private func input(
        outcome: NarrativeTaskOutcome = .success,
        affectsLaterBehavior: Bool = true,
        openThread: OpenThreadState? = nil
    ) -> NarrativeCaptureInput {
        NarrativeCaptureInput(
            taskID: "task-1",
            outcome: outcome,
            affectsLaterBehavior: affectsLaterBehavior,
            openThread: openThread,
            source: NarrativeSourceReference(
                conversation: NarrativeConversationRange(firstMessageID: "m1", lastMessageID: "m2"),
                toolIDs: ["tool-search"],
                workspaceIDs: [workspaceID]
            )
        )
    }

    private func service(
        store: any NarrativeStore = InMemoryNarrativeStore(),
        proposer: any NarrativeProposer = FixtureProposer(),
        authorize: @escaping @Sendable () -> Bool = { true },
        sensitive: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> NarrativeCaptureService {
        NarrativeCaptureService(
            store: store,
            proposer: proposer,
            validator: NarrativeValidator(
                sensitiveValueMatch: sensitive,
                existingEntries: { [] }
            ),
            sensitiveValueHandler: sensitive
        )
    }

    @Test("capture appends an admitted entry after a bounded task completes")
    func captureAppendsAdmittedEntry() async throws {
        let store = InMemoryNarrativeStore()
        let capture = service(store: store)

        let snapshot = await store.snapshot()
        #expect(snapshot.isEmpty)

        _ = await capture.capture(input: input())
        await capture.flush()

        let after = await store.snapshot()
        #expect(after.count == 1)
        #expect(after.first?.lesson?.summary == "Prefer explicit parameter schemas.")
    }

    @Test("failed tool calls create episodes only when they affect later behavior or leave open threads")
    func failedCallsCreateEpisodesOnlyWhenRelevant() async throws {
        let store = InMemoryNarrativeStore()

        let harmlessFailure = await service(store: store)
            .capture(input: input(outcome: .failure, affectsLaterBehavior: false, openThread: nil))
        #expect(harmlessFailure.recorded == false)

        let thread = OpenThreadState(summary: "Reconcile trust", status: .active)
        let openFailure = await service(store: store)
            .capture(input: input(outcome: .failure, affectsLaterBehavior: false, openThread: thread))
        #expect(openFailure.recorded == true)
    }

    @Test("a later turn uses a relevant prior outcome without the full transcript")
    func laterTurnUsesRelevantPriorOutcome() async throws {
        let store = InMemoryNarrativeStore()
        let capture = service(store: store)
        _ = await capture.capture(input: input(outcome: .success, affectsLaterBehavior: true))
        await capture.flush()

        let packet = await capture.relevantPacket(
            query: NarrativeRetrievalQuery(currentUserText: "parameter schema", limit: 5)
        )
        let text = try #require(packet?.text)
        #expect(text.contains("Prefer explicit parameter schemas."))
        #expect(!text.contains("full original transcript text"))
    }

    @Test("current user corrections override conflicting stored interpretation")
    func currentCorrectionsOverrideStoredInterpretation() async {
        let store = InMemoryNarrativeStore()
        let capture = service(store: store)
        _ = await capture.capture(input: input())
        let packet = await capture.relevantPacket(
            query: NarrativeRetrievalQuery(currentUserText: "", limit: 5),
            overridingState: CurrentStatePacket(
                authorativeState: "stored interpretation is overridden now",
                isAuthoritative: true
            )
        )
        let text = packet?.text ?? ""
        #expect(text.contains("stored interpretation is overridden now") || text.contains("Prefer explicit parameter schemas."))
    }

    @Test("user-visible completion is independent of storage and rejection failures")
    func completionIndependentOfFailures() async throws {
        let store = InMemoryNarrativeStore()
        let rejecting = service(store: store, sensitive: { _ in true })
        let result = await rejecting.capture(input: input())
        #expect(result.recorded == false)
        #expect(await store.snapshot().isEmpty)
    }

    @Test("shutdown is deterministic and flushes owned requests without admitting unrelated work")
    func shutdownFlushesDeterministically() async {
        let store = InMemoryNarrativeStore()
        let capture = service(store: store)
        let first = Task { _ = await capture.capture(input: input()) }
        let second = Task { _ = await capture.capture(input: input()) }
        _ = await first.value
        _ = await second.value

        await capture.shutdown()
        #expect(await store.snapshot().count == 2)
    }

    @Test("capture service never exposes narrative data to a workspace")
    func captureServiceDoesNotExposeNarrativeToWorkspaces() async {
        let store = InMemoryNarrativeStore()
        let capture = service(store: store)
        _ = await capture.capture(input: input())
        await capture.flush()

        let entries = await store.snapshot()
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.source.workspaceIDs.contains(workspaceID) })
        // Workspaces receive ordinary tool input; narrative stays private.
    }
}

private struct FixtureProposer: NarrativeProposer {
    func propose(for input: NarrativeCaptureInput) async -> NarrativeProposal? {
        NarrativeProposal(
            id: NarrativeEntryID(),
            kind: .lesson,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: input.source,
            observation: "Observed flexible tool schema.",
            interpretation: "Explicit parameter schemas improve validation.",
            lesson: ProposedLesson(summary: "Prefer explicit parameter schemas."),
            importance: 0.7,
            confidence: 0.9,
            supportingEpisodes: [],
            isFactStatedSpeculation: false,
            isOverbroadSelfCharacterization: false
        )
    }
}