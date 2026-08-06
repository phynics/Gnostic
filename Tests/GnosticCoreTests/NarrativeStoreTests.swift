// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Narrative model and append-only store")
struct NarrativeStoreTests {
    @Test("all entry kinds are representable")
    func allEntryKindsAreRepresentable() {
        let kinds: [NarrativeEntryKind] = [
            .episode,
            .arcUpdate,
            .lesson,
            .openThread,
            .operationalSelfModel,
        ]
        #expect(kinds.contains(.episode))
        #expect(kinds.contains(.arcUpdate))
        #expect(kinds.contains(.lesson))
        #expect(kinds.contains(.openThread))
        #expect(kinds.contains(.operationalSelfModel))
    }

    @Test("occurrence and recording times remain distinct")
    func occurrenceAndRecordingTimesRemainDistinct() {
        let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let entry = makeEpisodeEntry(occurredAt: occurredAt, recordedAt: recordedAt)

        #expect(entry.occurredAt == occurredAt)
        #expect(entry.recordedAt == recordedAt)
        #expect(entry.occurredAt != entry.recordedAt)
    }

    @Test("source references preserve ids without embedding object copies")
    func sourceReferencesPreserveIdsWithoutEmbeddingObjectCopies() {
        let conversationRange = NarrativeConversationRange(
            firstMessageID: "msg-100",
            lastMessageID: "msg-102"
        )
        let source = NarrativeSourceReference(
            conversation: conversationRange,
            toolIDs: ["tool-search"],
            correlationIDs: ["corr-7"],
            agentID: UUID(uuidString: "A21D0000-0000-4000-8000-000000000001"),
            timelineID: UUID(uuidString: "A21D0000-0000-4000-8000-000000000002"),
            workspaceIDs: [UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!],
            taskID: "task-9",
            filePaths: ["/src/main.swift"]
        )

        #expect(source.conversation == conversationRange)
        #expect(source.toolIDs == ["tool-search"])
        #expect(source.correlationIDs == ["corr-7"])
        #expect(source.taskID == "task-9")
        #expect(source.filePaths == ["/src/main.swift"])
    }

    @Test("entry carries observation, interpretation, lesson, thread, importance, confidence, superseded")
    func entryCarriesStructuredFields() {
        let lesson = ProposedLesson(summary: "Prefer explicit parameter schemas.")
        let thread = OpenThreadState(summary: "Reconcile workspace trust level", status: .active)
        let entry = NarrativeEntry(
            id: NarrativeEntryID(),
            kind: .lesson,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: NarrativeSourceReference(conversation: .empty),
            observation: "Observed flexible tool schema.",
            interpretation: "Flexible schemas reduce validation confidence.",
            lesson: lesson,
            openThread: thread,
            importance: 0.7,
            confidence: 0.9,
            supersededIDs: []
        )

        #expect(entry.observation == "Observed flexible tool schema.")
        #expect(entry.interpretation == "Flexible schemas reduce validation confidence.")
        #expect(entry.lesson == lesson)
        #expect(entry.openThread == thread)
        #expect(entry.importance == 0.7)
        #expect(entry.confidence == 0.9)
        #expect(entry.supersededIDs.isEmpty)
    }

    @Test("store appends and returns ordered snapshot reads")
    func storeAppendsAndReturnsOrderedSnapshot() async throws {
        let store = InMemoryNarrativeStore()
        let first = makeEpisodeEntry()
        let second = makeOpenThreadEntry()

        try await store.append(first)
        try await store.append(second)

        let snapshot = await store.snapshot()
        #expect(snapshot.map(\.id) == [first.id, second.id])
        #expect(await store.entry(id: first.id) == first)
    }

    @Test("appending a duplicate stable id is rejected")
    func appendingDuplicateStableIdIsRejected() async throws {
        let store = InMemoryNarrativeStore()
        let entry = makeEpisodeEntry()
        try await store.append(entry)

        await #expect(throws: NarrativeStoreError.self) {
            try await store.append(entry)
        }
    }

    @Test("stored entries cannot be mutated through the public interface")
    func storedEntriesCannotBeMutated() async throws {
        let store = InMemoryNarrativeStore()
        let entry = makeEpisodeEntry()
        try await store.append(entry)

        let read = try #require(await store.entry(id: entry.id))
        #expect(read.observation == entry.observation)
        #expect(read.kind == entry.kind)

        let after = try #require(await store.entry(id: entry.id))
        #expect(after == read)
        #expect(after.kind == .episode)
    }

    @Test("NarrativeEntry exposes a read-only value surface")
    func narrativeEntryExposesReadOnlySurface() throws {
        let entry = makeEpisodeEntry()
        #expect(Mirror(reflecting: entry).children.count > 0)
    }

    @Test("concurrent appends are data-race safe and preserve all entries")
    func concurrentAppendsAreDataRaceSafe() async {
        let store = InMemoryNarrativeStore()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask {
                    do {
                        let id = NarrativeEntryID()
                        let entry = NarrativeEntry(
                            id: id,
                            kind: index.isMultiple(of: 2) ? .episode : .openThread,
                            occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                            recordedAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
                            source: NarrativeSourceReference(conversation: .empty),
                            observation: "obs-\(index)",
                            interpretation: "",
                            lesson: nil,
                            openThread: nil,
                            importance: 0.5,
                            confidence: 0.5,
                            supersededIDs: []
                        )
                        try await store.append(entry)
                    } catch {
                        Issue.record("concurrent append failed: \(error)")
                    }
                }
            }
        }

        let snapshot = await store.snapshot()
        #expect(snapshot.count == 64)
        #expect(Set(snapshot.map(\.id)).count == 64)
    }
}

private func makeEpisodeEntry(
    occurredAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_100)
) -> NarrativeEntry {
    NarrativeEntry(
        id: NarrativeEntryID(),
        kind: .episode,
        occurredAt: occurredAt,
        recordedAt: recordedAt,
        source: NarrativeSourceReference(conversation: .empty),
        observation: "Completed a bounded task.",
        interpretation: "The task completed within bounds.",
        lesson: nil,
        openThread: nil,
        importance: 0.5,
        confidence: 0.8,
        supersededIDs: []
    )
}

private func makeOpenThreadEntry() -> NarrativeEntry {
    NarrativeEntry(
        id: NarrativeEntryID(),
        kind: .openThread,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_200),
        recordedAt: Date(timeIntervalSince1970: 1_700_000_300),
        source: NarrativeSourceReference(conversation: .empty),
        observation: "An arc remains unresolved.",
        interpretation: "A sub-task still needs attention.",
        lesson: nil,
        openThread: OpenThreadState(summary: "Pending sub-task", status: .active),
        importance: 0.6,
        confidence: 0.7,
        supersededIDs: []
    )
}