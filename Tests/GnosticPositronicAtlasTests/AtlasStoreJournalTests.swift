// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

import GnosticPositronicAtlas
import GnosticPositronicBackend

@Suite("Atlas store durable journal")
struct AtlasStoreJournalTests {
    private let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000001")!
    private let homeID = AscendantShardID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-000000000010")!)
    private let workID = AscendantShardID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-000000000020")!)

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-store-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("atlas.jsonl")
    }

    @Test("a restarted store replays registrations, reports, and accepted history")
    func restartReplaysState() async throws {
        let url = makeURL()
        let writer = InMemoryAtlasStore(ascendantID: ascendantID)
        try await writer.enableDurability(at: url)
        _ = try await writer.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        _ = try await writer.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))
        let draft = makeDraft(operationID: "turn-1")
        _ = try await writer.append(draft)

        let capture = await writer.capture()
        let patch = AtlasPatch(
            id: AtlasPatchID("patch-1"),
            capture: capture,
            operations: [.upsertItem(makeItem())],
            provenance: provenance(operationID: nil)
        )
        _ = try await writer.compareAndSwap(capture: capture, patch: patch)

        let expectedSnapshot = await writer.snapshot()
        let expectedRegistrations = await writer.registrations()
        let expectedPending = await writer.pendingReports()
        let expectedHistory = await writer.acceptedPatchHistory()

        let reader = InMemoryAtlasStore(ascendantID: ascendantID)
        try await reader.enableDurability(at: url)

        #expect(await reader.snapshot() == expectedSnapshot)
        #expect(await reader.registrations() == expectedRegistrations)
        #expect(await reader.pendingReports() == expectedPending)
        #expect(await reader.acceptedPatchHistory() == expectedHistory)
        #expect(try await reader.replay() == expectedSnapshot)
    }

    @Test("a restarted store replays a patch whose claim order differs from its sequence order")
    func restartReplaysOutOfOrderClaimSet() async throws {
        let url = makeURL()
        let writer = InMemoryAtlasStore(ascendantID: ascendantID)
        try await writer.enableDurability(at: url)
        _ = try await writer.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        // Sequence order (z then a) disagrees with report-ID order (a then z).
        _ = try await writer.append(makeDraft(operationID: "zz-later"))
        _ = try await writer.append(makeDraft(operationID: "aa-earlier"))

        let capture = await writer.capture()
        let patch = AtlasPatch(
            id: AtlasPatchID("patch-claims"),
            capture: capture,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        _ = try await writer.compareAndSwap(capture: capture, patch: patch)
        let expectedSnapshot = await writer.snapshot()
        let expectedHistory = await writer.acceptedPatchHistory()

        let reader = InMemoryAtlasStore(ascendantID: ascendantID)
        try await reader.enableDurability(at: url)

        #expect(await reader.snapshot() == expectedSnapshot)
        #expect(await reader.acceptedPatchHistory() == expectedHistory)
    }

    @Test("a recovered store keeps append and patch idempotency")
    func recoveryPreservesIdempotency() async throws {
        let url = makeURL()
        let writer = InMemoryAtlasStore(ascendantID: ascendantID)
        try await writer.enableDurability(at: url)
        _ = try await writer.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        let draft = makeDraft(operationID: "turn-1")
        _ = try await writer.append(draft)
        let capture = await writer.capture()
        let patch = AtlasPatch(
            id: AtlasPatchID("patch-1"),
            capture: capture,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        _ = try await writer.compareAndSwap(capture: capture, patch: patch)

        let reader = InMemoryAtlasStore(ascendantID: ascendantID)
        try await reader.enableDurability(at: url)

        let repeatedAppend = try await reader.append(draft)
        #expect(!repeatedAppend.wasInserted)

        let repeatedPatch = try await reader.compareAndSwap(capture: capture, patch: patch)
        #expect(repeatedPatch.wasIdempotent)
    }

    @Test("recovery rejects a journal written for another Ascendant")
    func recoveryRejectsForeignAscendant() async throws {
        let url = makeURL()
        let writer = InMemoryAtlasStore(ascendantID: ascendantID)
        try await writer.enableDurability(at: url)
        _ = try await writer.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))

        let other = InMemoryAtlasStore(ascendantID: UUID())
        await #expect(throws: AtlasStoreError.identityMismatch) {
            try await other.enableDurability(at: url)
        }
    }

    @Test("recovery keeps the valid prefix and drops a torn tail")
    func recoveryDropsTornTail() async throws {
        let url = makeURL()
        let writer = InMemoryAtlasStore(ascendantID: ascendantID)
        try await writer.enableDurability(at: url)
        _ = try await writer.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        _ = try await writer.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))

        let data = try Data(contentsOf: url)
        try Data(data.dropLast(12)).write(to: url)

        let reader = InMemoryAtlasStore(ascendantID: ascendantID)
        try await reader.enableDurability(at: url)
        #expect((await reader.registrations()).map(\.id) == [homeID])

        // The store keeps accepting mutations after recovery.
        _ = try await reader.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))
        #expect((await reader.registrations()).map(\.id) == [homeID, workID])
    }

    @Test("journal events round-trip through JSON")
    func journalEventsRoundTrip() throws {
        let events: [AtlasStoreEvent] = [
            .registered(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home")),
            .appended(AscendantShardReport(draft: makeDraft(operationID: "turn-1"), sequence: 1)),
            .accepted(AtlasPatch(
                id: AtlasPatchID("patch-1"),
                ascendantID: ascendantID,
                baseStateVersion: 0,
                captureID: AtlasCaptureID("capture-1"),
                operations: [.upsertItem(makeItem())],
                provenance: provenance(operationID: nil)
            )),
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(AtlasStoreEvent.self, from: data)
            #expect(decoded == event)
        }
    }

    private func makeDraft(operationID: String) -> ShardReportDraft {
        ShardReportDraft(
            ascendantID: ascendantID,
            shardID: homeID,
            operationID: operationID,
            content: "bounded report",
            provenance: AtlasProvenance(
                ascendantID: ascendantID,
                shardID: homeID,
                operationID: operationID,
                origin: .ascendantTurn
            )
        )
    }

    private func makeItem() -> AtlasItem {
        AtlasItem(
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "response-style",
            content: "Prefer explicit schemas.",
            kind: .preference,
            provenance: provenance(operationID: nil)
        )
    }

    private func provenance(operationID: String?) -> AtlasProvenance {
        AtlasProvenance(
            ascendantID: ascendantID,
            shardID: homeID,
            operationID: operationID,
            origin: .host
        )
    }
}
