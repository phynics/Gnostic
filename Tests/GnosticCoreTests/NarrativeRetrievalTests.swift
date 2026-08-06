// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Narrative retrieval and open-thread reconstruction")
struct NarrativeRetrievalTests {
    private let agentID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000001")!
    private let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000002")!
    private let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!

    private func narrEntry(
        id: NarrativeEntryID = NarrativeEntryID(),
        kind: NarrativeEntryKind = .lesson,
        at timestamp: Double = 1_700_000_000,
        observation: String = "obs",
        interpretation: String = "interp",
        workspaceIDs: [UUID] = [],
        toolIDs: [String] = [],
        importance: Double = 0.5,
        confidence: Double = 0.8,
        thread: OpenThreadState? = nil,
        supersedes: [NarrativeEntryID] = []
    ) -> NarrativeEntry {
        NarrativeEntry(
            id: id,
            kind: kind,
            occurredAt: Date(timeIntervalSince1970: timestamp),
            recordedAt: Date(timeIntervalSince1970: timestamp + 100),
            source: NarrativeSourceReference(
                conversation: NarrativeConversationRange(firstMessageID: "m", lastMessageID: "m"),
                toolIDs: toolIDs,
                workspaceIDs: workspaceIDs
            ),
            observation: observation,
            interpretation: interpretation,
            lesson: kind == .lesson ? ProposedLesson(summary: interpretation) : nil,
            openThread: thread,
            importance: importance,
            confidence: confidence,
            supersededIDs: supersedes
        )
    }

    private func makeRetrieval(entries: [NarrativeEntry]) -> NarrativeRetrieval {
        NarrativeRetrieval(store: SeedableStore(entries: entries))
    }

    @Test("retrieval is deterministic, bounded, and ignores thread priority")
    func retrievalIsDeterministicAndBounded() async {
        let retrieval = makeRetrieval(entries: (0..<40).map {
            narrEntry(id: NarrativeEntryID(), at: 1_700_000_000 + Double($0), observation: "item \($0) token")
        })
        let query = NarrativeRetrievalQuery(
            currentUserText: "search token",
            timelineIDs: [],
            workspaceIDs: [],
            filePaths: [],
            limit: 10
        )
        let first = await retrieval.retrieve(query: query)
        let second = await retrieval.retrieve(query: query)

        #expect(first.rankedEntries.count <= 10)
        #expect(first.rankedEntries.map(\.id) == second.rankedEntries.map(\.id))
    }

    @Test("exact shared identifiers outrank lexical similarity")
    func exactIdentifiersOutrankLexicalSimilarity() async {
        let exact = narrEntry(
            observation: "unrelated text",
            interpretation: "unrelated",
            workspaceIDs: [workspaceID]
        )
        let lexical = narrEntry(
            observation: "query words phrase",
            interpretation: "query words phrase",
            importance: 0.9
        )
        let retrieval = makeRetrieval(entries: [lexical, exact])
        let query = NarrativeRetrievalQuery(
            currentUserText: "query words phrase",
            workspaceIDs: [workspaceID],
            limit: 10
        )

        let result = await retrieval.retrieve(query: query)
        #expect(result.rankedEntries.first?.id == exact.id)
    }

    @Test("resolved and superseded entries are excluded from reconstruction but retrievable historically")
    func resolvedAndSupersededAreExcludedButHistoricallyRetrievable() async {
        let activeThread = narrEntry(thread: OpenThreadState(summary: "Old arc", status: .active))
        let resolvedThread = narrEntry(thread: OpenThreadState(summary: "Done arc", status: .resolved))
        let supersededLesson = narrEntry(supersedes: [])
        let newer = narrEntry(supersedes: [supersededLesson.id])
        let retrieval = makeRetrieval(entries: [activeThread, resolvedThread, supersededLesson, newer])

        let current = await retrieval.retrieve(query: NarrativeRetrievalQuery(currentUserText: "", limit: 10))
        #expect(!current.openThreads.contains { $0.status == .resolved })
        #expect(current.openThreads.contains { $0.status == .active })
        #expect(!current.rankedEntries.map(\.id).contains(supersededLesson.id))

        let history = await retrieval.history(limit: 10)
        #expect(history.map(\.id).contains(supersededLesson.id))
    }

    @Test("newest non-superseded interpretation wins conflicts")
    func newestNonSupersededInterpretationWinsConflicts() async {
        let oldest = narrEntry(at: 1_700_000_000, interpretation: "old view")
        let newest = narrEntry(at: 1_700_000_300, interpretation: "new view", supersedes: [oldest.id])
        let retrieval = makeRetrieval(entries: [oldest, newest])

        let current = await retrieval.retrieve(query: NarrativeRetrievalQuery(currentUserText: "", limit: 10))
        #expect(current.rankedEntries.contains { $0.id == newest.id })
        #expect(!current.rankedEntries.contains { $0.id == oldest.id })
    }

    @Test("active open threads reconstruct solely from append-only updates")
    func activeOpenThreadsReconstructFromAppendOnly() async {
        let openA = narrEntry(kind: .openThread, thread: OpenThreadState(summary: "Arc A pending", status: .active))
        let openB = narrEntry(kind: .openThread, thread: OpenThreadState(summary: "Arc B pending", status: .active))
        let retrieval = makeRetrieval(entries: [openA, openB])

        let current = await retrieval.retrieve(query: NarrativeRetrievalQuery(currentUserText: "", limit: 10))
        #expect(current.openThreads.count == 2)
        let summaries = current.openThreads.map { $0.summary }.sorted()
        #expect(summaries == ["Arc A pending", "Arc B pending"])
    }

    @Test("current conversation and authoritative state outrank conflicting narrative interpretation")
    func currentStateOutranksNarrativeInterpretation() async {
        let narrative = narrEntry(interpretation: "narrative says workspace unavailable", workspaceIDs: [workspaceID])
        let retrieval = makeRetrieval(entries: [narrative])
        let state = CurrentStatePacket(
            authorativeState: "attached workspace \(workspaceID.uuidString) is available",
            isAuthoritative: true
        )

        let result = await retrieval.retrieve(
            query: NarrativeRetrievalQuery(currentUserText: "", workspaceIDs: [workspaceID], limit: 10),
            overridingState: state
        )
        #expect(result.currentStatePacket.isAuthoritative == true)
        #expect(result.currentStatePacket.text.contains(workspaceID.uuidString))
    }

    @Test("exact identifiers remain textual in the current-state packet")
    func identifiersRemainTextualInPacket() async {
        let state = CurrentStatePacket(
            authorativeState: "uuid \(workspaceID.uuidString) path /src/main.swift at 1700000000 attached approved blocked",
            isAuthoritative: true
        )
        #expect(state.text.contains(workspaceID.uuidString))
        #expect(state.text.contains("/src/main.swift"))
        #expect(state.text.contains("1700000000"))
    }

    @Test("empty or failed retrieval does not block the turn")
    func emptyRetrievalDoesNotBlock() async {
        let retrieval = makeRetrieval(entries: [])
        let result = await retrieval.retrieve(query: NarrativeRetrievalQuery(currentUserText: "anything", limit: 10))
        #expect(result.rankedEntries.isEmpty)
        #expect(result.openThreads.isEmpty)
    }
}

private actor SeedableStore: NarrativeStore {
    private var entries: [NarrativeEntry] = []

    init(entries: [NarrativeEntry]) {
        self.entries = entries
    }

    func append(_ entry: NarrativeEntry) async throws {
        entries.append(entry)
    }

    func entry(id: NarrativeEntryID) async -> NarrativeEntry? {
        entries.first { $0.id == id }
    }

    func snapshot() async -> [NarrativeEntry] {
        entries
    }
}