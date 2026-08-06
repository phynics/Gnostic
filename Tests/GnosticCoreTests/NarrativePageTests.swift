// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Immutable narrative image pages")
struct NarrativePageTests {
    private let agentID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000001")!
    private let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!

    private func sampleEntries() -> [NarrativeEntry] {
        [
            NarrativeEntry(
                id: NarrativeEntryID(rawValue: UUID()),
                kind: .episode,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
                source: NarrativeSourceReference(
                    conversation: NarrativeConversationRange(firstMessageID: "m1", lastMessageID: "m2"),
                    toolIDs: ["tool-search"],
                    workspaceIDs: [workspaceID]
                ),
                observation: "Performed a bounded search.",
                interpretation: "Search completed within scope.",
                importance: 0.6,
                confidence: 0.9,
                supersededIDs: []
            ),
            NarrativeEntry(
                id: NarrativeEntryID(rawValue: UUID()),
                kind: .openThread,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_200),
                recordedAt: Date(timeIntervalSince1970: 1_700_000_300),
                source: NarrativeSourceReference(conversation: NarrativeConversationRange(firstMessageID: "m3", lastMessageID: "m3")),
                observation: "Arc remains open.",
                interpretation: "A sub-task still needs attention.",
                openThread: OpenThreadState(summary: "Reconcile trust", status: .active),
                importance: 0.7,
                confidence: 0.8,
                supersededIDs: []
            ),
        ]
    }

    private func extraLessonEntry() -> NarrativeEntry {
        NarrativeEntry(
            id: NarrativeEntryID(rawValue: UUID()),
            kind: .lesson,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_400),
            recordedAt: Date(timeIntervalSince1970: 1_700_000_500),
            source: NarrativeSourceReference(conversation: .empty),
            observation: "new observation",
            interpretation: "new interpretation",
            importance: 0.5,
            confidence: 0.5,
            supersededIDs: []
        )
    }

    @Test("freezing records stable source entry IDs and a content digest")
    func freezingRecordSourceIDsAndDigest() {
        let entries = sampleEntries()
        var renderer = NarrativePageRenderer()
        let page = renderer.freeze(entries: entries, title: "Arc summary")

        #expect(Set(page.sourceEntryIDs) == Set(entries.map(\.id)))
        #expect(page.sourceEntryIDs.count == entries.count)
        #expect(!page.contentDigest.isEmpty)
        #expect(page.title == "Arc summary")
    }

    @Test("existing pages are never regenerated when new entries arrive")
    func existingPagesNotRegeneratedWhenNewEntriesArrive() {
        var renderer = NarrativePageRenderer()
        let first = renderer.freeze(entries: sampleEntries(), title: "t")
        let firstID = first.id

        let laterEntries = sampleEntries() + [extraLessonEntry()]
        let second = renderer.freeze(entries: laterEntries, title: "t")

        #expect(second.id != firstID)
        #expect(renderer.page(id: firstID) != nil)
    }

    @Test("re-rendering identical input is byte-for-byte deterministic")
    func reRenderingIdenticalInputIsDeterministic() {
        let renderer = NarrativePageRenderer()
        let entries = sampleEntries()
        let a = renderer.render(entries: entries, title: "same")
        let b = renderer.render(entries: entries, title: "same")

        #expect(a.renderedBytes == b.renderedBytes)
        #expect(a.contentDigest == b.contentDigest)
    }

    @Test("page layout has labeled entries and stays understandable without color")
    func layoutHasLabeledEntries() {
        let renderer = NarrativePageRenderer()
        let page = renderer.render(entries: sampleEntries(), title: "Arc summary")
        let text = page.indexText
        #expect(text.contains("Arc summary"))
        #expect(text.contains("Episode"))
        #expect(text.contains("Open Thread"))
    }

    @Test("textual page index is a sufficient fallback when image loading fails")
    func textualIndexIsFallback() {
        let renderer = NarrativePageRenderer()
        let page = renderer.render(entries: sampleEntries(), title: "Arc summary")
        let index = page.indexText
        #expect(!index.isEmpty)
        #expect(index.contains(page.title))
        #expect(index.contains("Performed a bounded search."))
    }

    @Test("exact active identifiers and values remain text, not pixel-derived data")
    func identifiersRemainText() {
        let entry = NarrativeEntry(
            id: NarrativeEntryID(rawValue: UUID()),
            kind: .episode,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: NarrativeSourceReference(
                conversation: NarrativeConversationRange(firstMessageID: "m1", lastMessageID: "m2"),
                workspaceIDs: [workspaceID]
            ),
            observation: "used \(agentID.uuidString)",
            interpretation: "value=1700000000",
            importance: 0.5,
            confidence: 0.8,
            supersededIDs: []
        )
        let renderer = NarrativePageRenderer()
        let page = renderer.render(entries: [entry], title: "IDs")
        #expect(page.indexText.contains(agentID.uuidString))
        #expect(page.indexText.contains(workspaceID.uuidString))
        #expect(page.indexText.contains("value=1700000000"))
    }

    @Test("only relevant pages are selected for a turn using retrieval signals")
    func onlyRelevantPagesSelected() {
        var renderer = NarrativePageRenderer()
        let relevantEntry = sampleEntries()[0]
        let a = renderer.freeze(entries: [relevantEntry], title: "relevant")
        let b = renderer.freeze(entries: sampleEntries(), title: "other")

        let selected = renderer.selectRelevantPages(
            relevantEntryIDs: [relevantEntry.id],
            limit: 10
        )
        #expect(selected.contains { $0.id == a.id })
        #expect(!selected.contains { $0.id == b.id })
    }
}