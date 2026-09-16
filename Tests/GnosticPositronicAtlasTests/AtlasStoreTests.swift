// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

import GnosticPositronicAtlas

@Suite("Atlas model and store")
struct AtlasStoreTests {
    private let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000001")!
    private let homeID = AscendantShardID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-000000000010")!)
    private let workID = AscendantShardID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-000000000020")!)

    @Test("registration and append are deterministic and idempotent")
    func registrationAndAppendAreDeterministicAndIdempotent() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        let home = AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home")
        let work = AscendantShard(id: workID, ascendantID: ascendantID, name: "Work")

        #expect(try await store.register(home).wasInserted)
        #expect(!(try await store.register(home)).wasInserted)
        #expect(try await store.register(work).wasInserted)

        let draft = ShardReportDraft(
            ascendantID: ascendantID,
            shardID: homeID,
            operationID: "turn-1",
            content: "User prefers explicit schemas.",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
            provenance: AtlasProvenance(
                ascendantID: ascendantID,
                shardID: homeID,
                operationID: "turn-1",
                origin: .ascendantTurn
            )
        )

        let firstAppend = try await store.append(draft)
        let repeatedAppend = try await store.append(draft)

        #expect(firstAppend.wasInserted)
        #expect(!repeatedAppend.wasInserted)
        #expect(firstAppend.report.sequence == 1)
        #expect(repeatedAppend.report == firstAppend.report)

        let importedDraft = ShardReportDraft(
            ascendantID: ascendantID,
            shardID: homeID,
            operationID: "imported",
            content: "imported report",
            provenance: AtlasProvenance(
                ascendantID: ascendantID,
                shardID: homeID,
                origin: .atlasIntegration
            )
        )
        let importedReport = AscendantShardReport(draft: importedDraft, sequence: 2)
        let importedAppend = try await store.append(importedReport)
        let repeatedImportedDraft = try await store.append(importedDraft)
        #expect(importedAppend.wasInserted)
        #expect(!repeatedImportedDraft.wasInserted)
        #expect(repeatedImportedDraft.report == importedReport)

        let snapshot = await store.snapshot()
        #expect(snapshot.ascendantID == ascendantID)
        #expect((await store.registrations()).map(\.id) == [homeID, workID])
        #expect((await store.pendingReports()).map(\.id) == [firstAppend.report.id, importedReport.id])
    }

    @Test("a capture is immutable and late reports remain pending")
    func capturePreservesCausalCut() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))

        let first = try await store.append(makeDraft(operationID: "turn-1"))
        let capture = await store.capture()
        let late = try await store.append(makeDraft(operationID: "turn-2"))

        #expect(capture.pendingReports == [first.report])
        #expect(capture.watermarks == [AtlasWatermark(shardID: homeID, sequence: 1)])
        #expect((await store.pendingReports()).map(\.id) == [first.report.id, late.report.id])

        let patch = AtlasPatch(
            id: AtlasPatchID("patch-1"),
            capture: capture,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        let receipt = try await store.compareAndSwap(capture: capture, patch: patch)

        #expect(receipt.state.stateVersion == 1)
        #expect(receipt.state.semanticRevision == 0)
        #expect(receipt.state.watermarks == [AtlasWatermark(shardID: homeID, sequence: 1)])
        #expect((await store.pendingReports()).map(\.id) == [late.report.id])
    }

    @Test("semantic commits advance both versions and accepted history replays")
    func semanticCommitAndReplay() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        _ = try await store.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))

        let capture = await store.capture()
        let item = AtlasItem(
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "response-style",
            content: "Prefer explicit schemas.",
            kind: .preference,
            applicability: .shards([workID]),
            disclosure: .shards([workID]),
            epistemicStatus: .observed,
            provenance: provenance(operationID: nil)
        )
        let patch = AtlasPatch(
            id: AtlasPatchID("patch-semantic"),
            capture: capture,
            operations: [.upsertItem(item)],
            provenance: provenance(operationID: nil)
        )

        let receipt = try await store.compareAndSwap(capture: capture, patch: patch)

        #expect(receipt.state.stateVersion == 1)
        #expect(receipt.state.semanticRevision == 1)
        #expect(receipt.state.items == [item])
        let replayed = try await store.replay()
        let snapshot = await store.snapshot()
        #expect(replayed == snapshot)
        #expect((await store.acceptedPatchHistory()).map(\.stateVersion) == [1])
    }

    @Test("compare-and-swap rejects stale captures without partial mutation")
    func staleCompareAndSwapDoesNotMutateState() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        let firstCapture = await store.capture()
        let secondCapture = await store.capture()

        let firstPatch = AtlasPatch(
            id: AtlasPatchID("patch-first"),
            capture: firstCapture,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        _ = try await store.compareAndSwap(capture: firstCapture, patch: firstPatch)

        let stalePatch = AtlasPatch(
            id: AtlasPatchID("patch-stale"),
            capture: secondCapture,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        await #expect(throws: AtlasStoreError.self) {
            _ = try await store.compareAndSwap(capture: secondCapture, patch: stalePatch)
        }
        #expect((await store.snapshot()).stateVersion == 1)
        #expect((await store.acceptedPatchHistory()).count == 1)
    }

    @Test("identity, binding, reference, and watermark failures are structured and redacted")
    func failuresAreStructuredAndRedacted() async throws {
        let bindingID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000099")!
        let store = InMemoryAtlasStore(
            binding: AscendantAtlasBinding(ascendantID: ascendantID, bindingID: bindingID)
        )
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))

        let wrongIdentity = makeDraft(operationID: "wrong", ascendantID: UUID())
        await #expect(throws: AtlasStoreError.identityMismatch) {
            _ = try await store.append(wrongIdentity)
        }

        let wrongBinding = AscendantShard(
            id: workID,
            ascendantID: ascendantID,
            name: "Work",
            bindingID: UUID(uuidString: "A21D0000-0000-4000-8000-000000000098")!
        )
        await #expect(throws: AtlasStoreError.conflictingBinding) {
            _ = try await store.register(wrongBinding)
        }

        let capture = await store.capture()
        let missingReport = AtlasReportID(shardID: homeID, operationID: "missing")
        let missingClaimPatch = AtlasPatch(
            id: AtlasPatchID("patch-missing-report"),
            ascendantID: ascendantID,
            baseStateVersion: capture.baseStateVersion,
            captureID: capture.id,
            claimedReportIDs: [missingReport],
            watermarks: capture.watermarks,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        await #expect(throws: AtlasStoreError.claimedReportNotFound) {
            _ = try await store.compareAndSwap(capture: capture, patch: missingClaimPatch)
        }

        let invalidPatch = AtlasPatch(
            id: AtlasPatchID("patch-invalid"),
            capture: capture,
            operations: [.archiveItem(AtlasItemID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-000000000404")!))],
            provenance: provenance(operationID: nil)
        )
        do {
            _ = try await store.compareAndSwap(capture: capture, patch: invalidPatch)
            Issue.record("Expected invalid item reference to fail.")
        } catch let error as AtlasStoreError {
            #expect(error.reasonCode == "invalidReference")
            #expect(error.errorDomain == "me.atkn.gnostic.positronic-atlas")
            #expect(!error.userFriendlyMessage.contains("404"))
            #expect(!error.userFriendlyMessage.contains("secret"))
        }

        let secondStore = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await secondStore.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        let first = try await secondStore.append(makeDraft(operationID: "same"))
        let regressed = AtlasPatch(
            id: AtlasPatchID("patch-regressed"),
            ascendantID: ascendantID,
            baseStateVersion: 0,
            captureID: AtlasCaptureID("forged"),
            watermarks: [AtlasWatermark(shardID: homeID, sequence: 0)],
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        #expect(first.report.sequence == 1)
        await #expect(throws: AtlasStoreError.captureMismatch) {
            _ = try await secondStore.compareAndSwap(capture: await secondStore.capture(), patch: regressed)
        }
    }

    @Test("watermarks use the greatest value and reject regression")
    func watermarkCanonicalizationAndRegression() async throws {
        let state = AscendantAtlas(
            ascendantID: ascendantID,
            watermarks: [
                AtlasWatermark(shardID: homeID, sequence: 1),
                AtlasWatermark(shardID: homeID, sequence: 3),
            ]
        )
        #expect(state.watermark(for: homeID) == 3)

        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        let report = try await store.append(makeDraft(operationID: "watermark"))
        let capture = await store.capture()
        _ = try await store.compareAndSwap(
            capture: capture,
            patch: AtlasPatch(
                id: AtlasPatchID("consume-watermark"),
                capture: capture,
                operations: [.noOp],
                provenance: provenance(operationID: nil)
            )
        )

        let regressedCapture = AtlasIntegrationCapture(
            id: AtlasCaptureID("regressed-capture"),
            state: await store.snapshot(),
            registrations: await store.registrations(),
            watermarks: [AtlasWatermark(shardID: homeID, sequence: 0)],
            pendingReports: []
        )
        let regressedPatch = AtlasPatch(
            id: AtlasPatchID("watermark-regression"),
            capture: regressedCapture,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        #expect(report.report.sequence == 1)
        await #expect(throws: AtlasStoreError.watermarkRegression) {
            _ = try await store.compareAndSwap(capture: regressedCapture, patch: regressedPatch)
        }
    }

    @Test("re-registration ignores an absent binding but rejects changed fields")
    func reRegistrationIsIdempotentAcrossAbsentBinding() async throws {
        let bindingID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000077")!
        let store = InMemoryAtlasStore(
            binding: AscendantAtlasBinding(ascendantID: ascendantID, bindingID: bindingID)
        )
        let explicit = AscendantShard(
            id: homeID,
            ascendantID: ascendantID,
            name: "Home",
            bindingID: bindingID
        )
        #expect(try await store.register(explicit).wasInserted)

        let absentBinding = AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home")
        let repeated = try await store.register(absentBinding)
        #expect(!repeated.wasInserted)
        #expect(repeated.shard.bindingID == bindingID)

        let renamed = AscendantShard(id: homeID, ascendantID: ascendantID, name: "Renamed")
        await #expect(throws: AtlasStoreError.registrationConflict) {
            _ = try await store.register(renamed)
        }

        let stored = try #require((await store.registrations()).first)
        #expect(stored.name == "Home")
    }

    @Test("decimal values use one canonical numeric spelling")
    func decimalUsesOneCanonicalSpelling() {
        #expect(AtlasDecimal("1")?.canonical == "1")
        #expect(AtlasDecimal("-42.50")?.canonical == "-42.5")
        #expect(AtlasDecimal("007.50")?.canonical == "7.5")
        #expect(AtlasDecimal("0.0")?.canonical == "0")
        #expect(AtlasDecimal("-0.0")?.canonical == "0")
        #expect(AtlasDecimal("4.5e-3")?.canonical == "4.5e-3")
        #expect(AtlasDecimal("1") == AtlasDecimal("1.0"))
        #expect(AtlasDecimal("7.5") == AtlasDecimal("007.50"))

        #expect(AtlasDecimal("1.") == nil)
        #expect(AtlasDecimal("-42.") == nil)
        #expect(AtlasDecimal("1.e5") == nil)
        #expect(AtlasDecimal(".5") == nil)
        #expect(AtlasDecimal("+3") == nil)
        #expect(AtlasDecimal("+") == nil)
        #expect(AtlasDecimal("abc") == nil)
        #expect(AtlasDecimal("1.2.3") == nil)
    }

    @Test("canonical state encoding is independent of input order")
    func canonicalStateEncoding() throws {
        let firstItem = AtlasItem(
            id: AtlasItemID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-0000000000A1")!),
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "alpha",
            value: .text("one"),
            applicability: .shards([workID, homeID]),
            disclosure: .shards([workID]),
            provenance: provenance(operationID: nil)
        )
        let secondItem = AtlasItem(
            id: AtlasItemID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-0000000000A2")!),
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "beta",
            value: .text("two"),
            provenance: provenance(operationID: nil)
        )
        let first = AscendantAtlas(
            ascendantID: ascendantID,
            items: [secondItem, firstItem],
            watermarks: [
                AtlasWatermark(shardID: homeID, sequence: 1),
                AtlasWatermark(shardID: homeID, sequence: 3),
            ]
        )
        let second = AscendantAtlas(
            ascendantID: ascendantID,
            items: [firstItem, secondItem],
            watermarks: [AtlasWatermark(shardID: homeID, sequence: 3)]
        )

        #expect(first == second)
        #expect(try first.canonicalData() == second.canonicalData())
        #expect(first.items.map(\.id) == [firstItem.id, secondItem.id])
    }

    @Test("decoding canonicalizes noncanonical input and never traps")
    func decodingCanonicalizesState() throws {
        let json = """
        {
          "schemaVersion": 1,
          "ascendantID": "\(ascendantID.uuidString)",
          "stateVersion": 1,
          "semanticRevision": 0,
          "items": [],
          "conflicts": [],
          "directives": [],
          "watermarks": [
            { "shardID": { "rawValue": "\(UUID(uuidString: "A21D0000-0000-4000-8000-000000000010")!)" }, "sequence": 7 },
            { "shardID": { "rawValue": "\(UUID(uuidString: "A21D0000-0000-4000-8000-000000000010")!)" }, "sequence": 2 }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AscendantAtlas.self, from: json)

        #expect(decoded.watermark(for: homeID) == 7)
        #expect(decoded.watermarks.count == 1)
        #expect(try decoded.canonicalData() == AscendantAtlas(
            ascendantID: ascendantID,
            stateVersion: 1,
            watermarks: [AtlasWatermark(shardID: homeID, sequence: 7)]
        ).canonicalData())
    }

    @Test("decoded identity is normalized to the canonical spelling")
    func decodedIdentityIsNormalized() throws {
        let json = #"{"rawValue":"  turn-1  "}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AtlasOperationID.self, from: json)
        #expect(decoded == AtlasOperationID("turn-1"))
    }

    @Test("accepted history replays at each historical version")
    func multiPatchHistoryReplaysToEarlierVersions() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))

        let firstItem = AtlasItem(
            id: AtlasItemID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-0000000000B1")!),
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "first",
            value: .text("one"),
            provenance: provenance(operationID: nil)
        )
        let firstCapture = await store.capture()
        _ = try await store.compareAndSwap(
            capture: firstCapture,
            patch: AtlasPatch(
                id: AtlasPatchID("patch-one"),
                capture: firstCapture,
                operations: [.upsertItem(firstItem)],
                provenance: provenance(operationID: nil)
            )
        )

        let secondItem = AtlasItem(
            id: AtlasItemID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-0000000000B2")!),
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "second",
            value: .text("two"),
            provenance: provenance(operationID: nil)
        )
        let secondCapture = await store.capture()
        _ = try await store.compareAndSwap(
            capture: secondCapture,
            patch: AtlasPatch(
                id: AtlasPatchID("patch-two"),
                capture: secondCapture,
                operations: [.upsertItem(secondItem)],
                provenance: provenance(operationID: nil)
            )
        )

        let history = await store.acceptedPatchHistory()
        #expect(history.map(\.stateVersion) == [1, 2])
        #expect((await store.acceptedPatchHistory(after: 1)).map(\.id) == [AtlasPatchID("patch-two")])

        let replayedFirst = try await store.replay(to: 1)
        #expect(replayedFirst.items == [firstItem])
        #expect(replayedFirst.semanticRevision == 1)

        let replayedAll = try await store.replay()
        let liveSnapshot = await store.snapshot()
        #expect(replayedAll == liveSnapshot)

        let replayedZero = try await store.replay(to: 0)
        #expect(replayedZero.items.isEmpty)
        #expect(replayedZero.stateVersion == 0)
    }

    @Test("a registration after capture invalidates the capture")
    func registrationAfterCaptureIsStale() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        let capture = await store.capture()

        _ = try await store.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))

        let patch = AtlasPatch(
            id: AtlasPatchID("patch-after-registration"),
            capture: capture,
            operations: [.noOp],
            provenance: provenance(operationID: nil)
        )
        await #expect(throws: AtlasStoreError.catalogChanged) {
            _ = try await store.compareAndSwap(capture: capture, patch: patch)
        }
        #expect((await store.snapshot()).stateVersion == 0)
        #expect((await store.acceptedPatchHistory()).isEmpty)

        let fresh = await store.capture()
        let recovered = try await store.compareAndSwap(
            capture: fresh,
            patch: AtlasPatch(
                id: AtlasPatchID("patch-after-registration"),
                capture: fresh,
                operations: [.noOp],
                provenance: provenance(operationID: nil)
            )
        )
        #expect(recovered.wasIdempotent == false)
    }

    @Test("concurrent drafts receive complete independent Shard sequences")
    func concurrentAppendsPreservePerShardSequences() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        _ = try await store.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))

        let reports = await withTaskGroup(of: AtlasAppendResult?.self, returning: [AtlasAppendResult].self) { group in
            for index in 0..<64 {
                group.addTask {
                    try? await store.append(makeDraft(
                        operationID: "home-\(index)",
                        shardID: homeID
                    ))
                }
                group.addTask {
                    try? await store.append(makeDraft(
                        operationID: "work-\(index)",
                        shardID: workID
                    ))
                }
            }

            var values: [AtlasAppendResult] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }

        #expect(reports.count == 128)
        #expect(Set(reports.filter { $0.report.shardID == homeID }.map { $0.report.sequence }) == Set((1...64).map(UInt64.init)))
        #expect(Set(reports.filter { $0.report.shardID == workID }.map { $0.report.sequence }) == Set((1...64).map(UInt64.init)))
    }

    private func makeDraft(
        operationID: String,
        ascendantID: UUID? = nil,
        shardID: AscendantShardID? = nil
    ) -> ShardReportDraft {
        let id = ascendantID ?? self.ascendantID
        let source = shardID ?? homeID
        return ShardReportDraft(
            ascendantID: id,
            shardID: source,
            operationID: operationID,
            content: "bounded report",
            provenance: AtlasProvenance(
                ascendantID: id,
                shardID: source,
                operationID: operationID,
                origin: .ascendantTurn
            )
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
