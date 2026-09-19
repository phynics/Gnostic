// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticPositronicAtlas
import PositronicKit
import Testing

@Suite("Atlas Turn correlation", .timeLimit(.minutes(2)))
struct AtlasTurnCorrelationTests {
    private let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000101")!
    private let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000102")!
    private let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000103")!
    private let homeID = AscendantShardID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-000000000110")!)
    private let workID = AscendantShardID(rawValue: UUID(uuidString: "A21D0000-0000-4000-8000-000000000120")!)

    // MARK: - Success, replay, conflict

    @Test("a successful Turn records exactly one deterministic report")
    func successfulTurnRecordsOneReport() async throws {
        let harness = try await makeHarness()

        let result = try await execute(harness, clientTurnID: "turn-1")
        let record = try #require(await harness.inbox.next())

        #expect(!result.replayed)
        let reports = await harness.store.pendingReports()
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.operationID == AtlasOperationID(record.operationID))
        #expect(report.id == AtlasReportID(shardID: homeID, operationID: record.operationID))
        #expect(report.sequence == 1)
        #expect(report.outcome == .succeeded)
        #expect(report.provenance.origin == .ascendantTurn)
        #expect(report.provenance.ascendantID == ascendantID)
        #expect(report.provenance.shardID == homeID)
        #expect(report.provenance.timelineID == timelineID)
        #expect(report.projectedVersion == AtlasVersion(stateVersion: 0, semanticRevision: 0))
    }

    @Test("completed replay records no second report")
    func completedReplayRecordsNoSecondReport() async throws {
        let harness = try await makeHarness()

        _ = try await execute(harness, clientTurnID: "turn-1")
        _ = try #require(await harness.inbox.next())
        let replay = try await execute(harness, clientTurnID: "turn-1")

        #expect(replay.replayed)
        #expect(await harness.inbox.records.count == 1)
        #expect((await harness.store.pendingReports()).count == 1)
    }

    @Test("in-flight duplicate records no second report")
    func inFlightDuplicateRecordsNoSecondReport() async throws {
        let harness = try await makeHarness()
        let gate = TurnGate()

        let first = Task {
            try await execute(harness, clientTurnID: "turn-1") {
                await gate.markStarted()
                await gate.waitForRelease()
                return "reply"
            }
        }
        await gate.waitForStart()
        let duplicate = Task {
            try await execute(harness, clientTurnID: "turn-1")
        }
        await Task.yield()
        await gate.releaseTurn()

        let firstResult = try await first.value
        let duplicateResult = try await duplicate.value
        _ = try #require(await harness.inbox.next())

        #expect(!firstResult.replayed)
        #expect(duplicateResult.replayed)
        #expect(await harness.inbox.records.count == 1)
        #expect((await harness.store.pendingReports()).count == 1)
    }

    @Test("conflicting client identity records no report")
    func conflictRecordsNoReport() async throws {
        let harness = try await makeHarness()

        _ = try await execute(harness, clientTurnID: "turn-1", message: "one")
        _ = try #require(await harness.inbox.next())
        await #expect(throws: AscendantTurnError.self) {
            _ = try await execute(harness, clientTurnID: "turn-1", message: "different")
        }

        #expect(await harness.inbox.records.count == 1)
        #expect((await harness.store.pendingReports()).count == 1)
    }

    @Test("a client Turn id reused across Timelines records two distinct reports")
    func crossTimelineReuseRecordsDistinctReports() async throws {
        let harness = try await makeHarness()

        _ = try await execute(harness, timelineID: secondTimelineID, clientTurnID: "shared")
        _ = try await execute(harness, clientTurnID: "shared")
        _ = try #require(await harness.inbox.next())
        _ = try #require(await harness.inbox.next())

        let reports = await harness.store.pendingReports()
        #expect(reports.count == 2)
        #expect(Set(reports.map(\.id)).count == 2)
        let recordIDs = Set(await harness.inbox.records.map(\.operationID))
        #expect(Set(reports.map { $0.operationID.rawValue }) == recordIDs)
    }

    // MARK: - Terminal outcomes

    @Test("a terminal failure records one bounded failure report")
    func failureRecordsBoundedReport() async throws {
        let harness = try await makeHarness()
        let timeline = timelineID

        await #expect(throws: AscendantTurnError.self) {
            _ = try await execute(harness, clientTurnID: "turn-fail") {
                throw AscendantTurnError.terminal(
                    timelineID: timeline,
                    clientTurnID: "turn-fail",
                    code: "providerUnavailable",
                    detail: "The provider refused the request.",
                    retryable: true,
                    statusCode: 503
                )
            }
        }
        _ = try #require(await harness.inbox.next())

        let reports = await harness.store.pendingReports()
        #expect(reports.count == 1)
        #expect(reports.first?.outcome == .failed(reasonCode: "providerUnavailable"))
    }

    @Test("a cancellation records one cancellation report")
    func cancellationRecordsReport() async throws {
        let harness = try await makeHarness()

        await #expect(throws: AscendantTurnError.self) {
            _ = try await execute(harness, clientTurnID: "turn-cancel") {
                throw CancellationError()
            }
        }
        _ = try #require(await harness.inbox.next())

        let reports = await harness.store.pendingReports()
        #expect(reports.count == 1)
        #expect(reports.first?.outcome == .cancelled)
    }

    // MARK: - Origin suppression

    @Test("Atlas-origin activity is not recaptured as ordinary work")
    func atlasOriginIsSuppressed() async throws {
        let harness = try await makeHarness(origin: .atlasIntegration)

        _ = try await execute(harness, clientTurnID: "turn-origin")
        _ = try #require(await harness.inbox.next())

        #expect((await harness.store.pendingReports()).isEmpty)
        #expect(await harness.correlator.pendingCount == 0)
    }

    // MARK: - Unidentified Turn

    @Test("an unidentified Turn records a report without a projected revision")
    func unidentifiedTurnRecordsReportWithoutProjectedRevision() async throws {
        let harness = try await makeHarness()

        _ = try await execute(harness, clientTurnID: nil)
        let record = try #require(await harness.inbox.next())

        let reports = await harness.store.pendingReports()
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.operationID == AtlasOperationID(record.operationID))
        #expect(report.projectedVersion == nil)
        #expect(report.provenance.origin == .ascendantTurn)
    }

    // MARK: - Revision projection

    @Test("a report keeps the revision captured for prompt assembly, not a later revision")
    func reportKeepsProjectedRevision() async throws {
        let harness = try await makeHarness()
        let modelStore = harness.store
        let home = homeID
        let ascendant = ascendantID

        _ = try await execute(harness, clientTurnID: "turn-revision") {
            // The context source captured revision 0 during prompt assembly.
            // Advance accepted state before the terminal boundary.
            let capture = await modelStore.capture()
            let item = AtlasItem(
                ascendantID: ascendant,
                sourceShardID: home,
                key: "response-style",
                value: .text("Prefer explicit schemas."),
                kind: .preference,
                provenance: AtlasProvenance(
                    ascendantID: ascendant,
                    shardID: home,
                    origin: .host
                )
            )
            _ = try await modelStore.compareAndSwap(
                capture: capture,
                patch: AtlasPatch(
                    id: AtlasPatchID("bump-revision"),
                    capture: capture,
                    operations: [.upsertItem(item)],
                    provenance: AtlasProvenance(ascendantID: ascendant, shardID: home, origin: .host)
                )
            )
            return "reply"
        }
        _ = try #require(await harness.inbox.next())

        let live = await harness.store.snapshot()
        #expect(live.semanticRevision == 1)
        let report = try #require(await harness.store.pendingReports().first)
        #expect(report.projectedVersion == AtlasVersion(stateVersion: 0, semanticRevision: 0))
    }

    // MARK: - Projection determinism

    @Test("the projected brief is bounded, deterministic, and pins the first snapshot")
    func projectionIsDeterministicAndBounded() async throws {
        let harness = try await makeHarness()
        let modelStore = harness.store
        let home = homeID
        let ascendant = ascendantID

        try await seedItem(modelStore, ascendant: ascendant, shard: home, key: "response-style", text: "Prefer explicit schemas.")

        let first = try await project(harness, clientTurnID: "turn-projection")
        let firstText = try #require(first.first?.value.textValue)
        #expect(first.count == 1)
        #expect(firstText.contains("revision=1"))
        #expect(firstText.count <= AscendantBriefProjector.maximumCharacters)

        // Advance state, then project again for the same Turn. The first
        // immutable snapshot must win so prompt and report cannot drift.
        try await seedItem(modelStore, ascendant: ascendant, shard: home, key: "later-style", text: "Project the live revision.")

        let second = try await project(harness, clientTurnID: "turn-projection")
        #expect(second.first?.value.textValue == firstText)
    }

    // MARK: - Generic seam consumption

    @Test("the Atlas recorder consumes the generic terminal observer seam")
    func recorderConsumesGenericObserverSeam() async throws {
        let harness = try await makeHarness()
        let observer: any TerminalTurnObserving = harness.recorder
        #expect(observer is AtlasShardReportRecorder)
    }

    @Test("the Atlas contribution exposes one Turn context source and no tools")
    func contributionExposesContextSource() async throws {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        let integration = AtlasTurnIntegration(store: store, shardID: homeID)
        #expect(integration.contribution.label == "atlas.turn")
        #expect(integration.contribution.tools().isEmpty)
        #expect(integration.contribution.turnContextSource() != nil)
    }

    // MARK: - Harness

    private struct Harness {
        let store: InMemoryAtlasStore
        let correlator: AtlasTurnCorrelator
        let source: AtlasTurnContextSource
        let recorder: AtlasShardReportRecorder
        let inbox: TurnObservationInbox
        let coordinator: AscendantTurnCoordinator
    }

    private func makeHarness(origin: AtlasOrigin = .ascendantTurn) async throws -> Harness {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        _ = try await store.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))
        let correlator = AtlasTurnCorrelator()
        let source = AtlasTurnContextSource(
            store: store,
            correlator: correlator,
            shardID: homeID,
            origin: origin
        )
        let recorder = AtlasShardReportRecorder(
            store: store,
            correlator: correlator,
            shardID: homeID,
            origin: origin
        )
        // The inbox is the trailing observer, so its delivery means the
        // recorder has already appended.
        let inbox = TurnObservationInbox()
        let coordinator = AscendantTurnCoordinator(observers: [recorder, inbox])
        return Harness(
            store: store,
            correlator: correlator,
            source: source,
            recorder: recorder,
            inbox: inbox,
            coordinator: coordinator
        )
    }

    private func seedItem(
        _ store: InMemoryAtlasStore,
        ascendant: UUID,
        shard: AscendantShardID,
        key: String,
        text: String
    ) async throws {
        let capture = await store.capture()
        let item = AtlasItem(
            ascendantID: ascendant,
            sourceShardID: shard,
            key: key,
            value: .text(text),
            kind: .preference,
            applicability: .ascendant,
            disclosure: .ascendant,
            provenance: AtlasProvenance(ascendantID: ascendant, shardID: shard, origin: .host)
        )
        _ = try await store.compareAndSwap(
            capture: capture,
            patch: AtlasPatch(
                id: AtlasPatchID("seed-\(key)"),
                capture: capture,
                operations: [.upsertItem(item)],
                provenance: AtlasProvenance(ascendantID: ascendant, shardID: shard, origin: .host)
            )
        )
    }

    private func execute(
        _ harness: Harness,
        timelineID: UUID? = nil,
        clientTurnID: String?,
        message: String = "hello",
        body: @escaping @Sendable () async throws -> String = { "reply" }
    ) async throws -> AscendantTurnResult {
        let timeline = timelineID ?? self.timelineID
        let request = AscendantTurnRequest(message: message, timelineID: timeline, clientTurnID: clientTurnID)
        let source = harness.source
        let ascendantID = ascendantID
        return try await harness.coordinator.execute(request, ascendantID: ascendantID) {
            try await PositronicTurnInvocationContext.$current.withValue(
                PositronicTurnInvocation(ascendantID: ascendantID, timelineID: timeline, turnID: clientTurnID)
            ) {
                _ = try await source.contributions(for: TurnContextRequest(
                    threadID: timeline,
                    turnID: UUID(),
                    requestID: UUID(),
                    agentID: ascendantID,
                    executionKind: .agentManaged,
                    message: message
                ))
                return try await body()
            }
        }
    }

    private func project(
        _ harness: Harness,
        clientTurnID: String
    ) async throws -> [TurnContextContribution] {
        let source = harness.source
        let ascendantID = ascendantID
        let timelineID = timelineID
        return try await PositronicTurnInvocationContext.$current.withValue(
            PositronicTurnInvocation(ascendantID: ascendantID, timelineID: timelineID, turnID: clientTurnID)
        ) {
            try await source.contributions(for: TurnContextRequest(
                threadID: timelineID,
                turnID: UUID(),
                requestID: UUID(),
                agentID: ascendantID,
                executionKind: .agentManaged,
                message: "hello"
            ))
        }
    }
}

/// Captures the generic terminal records and lets a test wait for delivery.
private actor TurnObservationInbox: TerminalTurnObserving {
    private(set) var records: [TerminalTurnRecord] = []
    private var readIndex = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func observe(_ record: TerminalTurnRecord) async throws {
        records.append(record)
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if records.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func next() async -> TerminalTurnRecord? {
        let target = readIndex + 1
        await wait(forCount: target)
        guard records.count >= target else { return nil }
        readIndex = target
        return records[target - 1]
    }

    private func wait(forCount count: Int) async {
        if records.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// A one-shot gate that keeps the first Turn in flight until the test releases it.
private actor TurnGate {
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var didRelease = false

    func waitForStart() async {
        if didStart { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func markStarted() {
        didStart = true
        startWaiter?.resume()
        startWaiter = nil
    }

    func waitForRelease() async {
        if didRelease { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func releaseTurn() {
        didRelease = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
