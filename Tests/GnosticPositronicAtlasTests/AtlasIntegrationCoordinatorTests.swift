// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

import GnosticPositronicAtlas

@Suite("Atlas integration coordinator")
struct AtlasIntegrationCoordinatorTests {
    private let ascendantID = UUID(uuidString: "A1170000-0000-4000-8000-000000000101")!
    private let otherAscendantID = UUID(uuidString: "A1170000-0000-4000-8000-000000000102")!
    private let homeID = AscendantShardID(rawValue: UUID(uuidString: "A1170000-0000-4000-8000-000000000110")!)

    // MARK: - Versioning and diagnostics

    @Test("a captured cut commits as a watermark-only stateVersion advance")
    func watermarkOnlyCommit() async throws {
        let store = try await seededStore()
        _ = try await appendReport(to: store, operationID: "turn-1")
        let coordinator = AtlasIntegrationCoordinator(store: store, integrator: AtlasNoOpIntegrator())

        let outcome = try await coordinator.flush()
        let receipt = try #require(outcome.receipt)
        let diagnostic = try #require(outcome.diagnostic)

        #expect(receipt.state.stateVersion == 1)
        #expect(receipt.state.semanticRevision == 0)
        #expect(!diagnostic.isSemantic)
        #expect(diagnostic.attempt == 1)
        #expect(diagnostic.consumedReportCount == 1)
        #expect((await store.pendingReports()).isEmpty)
        #expect(try await coordinator.flush() == .noWork)
    }

    @Test("a semantic commit advances both versions and publishes a redacted diagnostic")
    func semanticCommitIsRedacted() async throws {
        let store = try await seededStore()
        _ = try await appendReport(to: store, operationID: "turn-1")
        let observer = DiagnosticCollector()
        let homeID = self.homeID
        let integrator = AtlasFixtureIntegrator { request in
            AtlasIntegrationProposal(
                operations: [.upsertItem(AtlasItem(
                    ascendantID: request.capture.ascendantID,
                    sourceShardID: homeID,
                    key: "response-style",
                    value: .text("SENSITIVE-VALUE"),
                    kind: .preference,
                    applicability: .ascendant,
                    disclosure: .ascendant,
                    epistemicStatus: .reported,
                    provenance: AtlasProvenance(
                        ascendantID: request.capture.ascendantID,
                        shardID: homeID,
                        origin: .atlasIntegration
                    )
                ))],
                rationale: "SENSITIVE-RATIONALE"
            )
        }
        let coordinator = AtlasIntegrationCoordinator(store: store, integrator: integrator, observer: observer)

        let outcome = try await coordinator.flush()
        let receipt = try #require(outcome.receipt)
        let diagnostic = try #require(outcome.diagnostic)

        #expect(receipt.state.stateVersion == 1)
        #expect(receipt.state.semanticRevision == 1)
        #expect(receipt.state.items.count == 1)
        #expect(diagnostic.isSemantic)
        #expect(diagnostic.itemCount == 1)
        #expect(diagnostic.operationCount == 1)

        let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        #expect(!encoded.contains("SENSITIVE-VALUE"))
        #expect(!encoded.contains("SENSITIVE-RATIONALE"))
        #expect(!encoded.contains("response-style"))
        #expect(await observer.diagnostics == [diagnostic])
    }

    @Test("an invalid proposal is rejected without changing accepted state")
    func invalidProposalDoesNotChangeState() async throws {
        let store = try await seededStore()
        _ = try await appendReport(to: store, operationID: "turn-1")
        let homeID = self.homeID
        let integrator = AtlasFixtureIntegrator { request in
            AtlasIntegrationProposal(operations: [.upsertItem(AtlasItem(
                ascendantID: request.capture.ascendantID,
                sourceShardID: homeID,
                key: "host-claim",
                value: .text("v"),
                provenance: AtlasProvenance(
                    ascendantID: request.capture.ascendantID,
                    shardID: homeID,
                    origin: .host
                )
            ))])
        }
        let coordinator = AtlasIntegrationCoordinator(store: store, integrator: integrator)

        await #expect(throws: AtlasIntegrationError.authorityViolation) {
            _ = try await coordinator.flush()
        }
        #expect((await store.snapshot()).stateVersion == 0)
        #expect((await store.acceptedPatchHistory()).isEmpty)
        #expect((await store.pendingReports()).count == 1)
        #expect(!(await coordinator.isFlushing))
    }

    // MARK: - Single flight

    @Test("concurrent flushes for one Ascendant share one task")
    func concurrentFlushesShareOneTask() async throws {
        let store = try await seededStore()
        _ = try await appendReport(to: store, operationID: "turn-1")
        let barrier = IntegrationBarrier()
        let integrator = BarrierIntegrator(barrier: barrier)
        let coordinator = AtlasIntegrationCoordinator(store: store, integrator: integrator)

        let outcomes = await withTaskGroup(of: AtlasIntegrationOutcome?.self, returning: [AtlasIntegrationOutcome].self) { group in
            for _ in 0..<16 {
                group.addTask { try? await coordinator.flush() }
            }
            await barrier.waitForEntered(1)
            #expect(await integrator.invocationCount() == 1)
            await barrier.release()

            var collected: [AtlasIntegrationOutcome] = []
            for await outcome in group {
                if let outcome { collected.append(outcome) }
            }
            return collected
        }

        #expect(outcomes.count == 16)
        #expect(outcomes.allSatisfy { $0.receipt?.state.stateVersion == 1 })
        #expect(await integrator.invocationCount() == 1)
    }

    @Test("different Ascendants integrate independently")
    func differentAscendantsProceedIndependently() async throws {
        let firstStore = try await seededStore(ascendantID: ascendantID)
        let secondStore = try await seededStore(ascendantID: otherAscendantID)
        _ = try await appendReport(to: firstStore, operationID: "first")
        _ = try await appendReport(to: secondStore, operationID: "second")

        let barrier = IntegrationBarrier()
        let firstIntegrator = BarrierIntegrator(barrier: barrier)
        let secondIntegrator = BarrierIntegrator(barrier: barrier)
        let firstCoordinator = AtlasIntegrationCoordinator(store: firstStore, integrator: firstIntegrator)
        let secondCoordinator = AtlasIntegrationCoordinator(store: secondStore, integrator: secondIntegrator)

        async let first = firstCoordinator.flush()
        async let second = secondCoordinator.flush()

        await barrier.waitForEntered(2)
        #expect(await firstIntegrator.invocationCount() == 1)
        #expect(await secondIntegrator.invocationCount() == 1)
        await barrier.release()

        let firstOutcome = try await first
        let secondOutcome = try await second
        #expect(firstOutcome.receipt?.state.ascendantID == ascendantID)
        #expect(secondOutcome.receipt?.state.ascendantID == otherAscendantID)
        #expect(firstOutcome.receipt?.state.stateVersion == 1)
        #expect(secondOutcome.receipt?.state.stateVersion == 1)
    }

    // MARK: - Lateness and retry

    @Test("reports arriving during integration remain pending")
    func lateReportsRemainPending() async throws {
        let store = try await seededStore()
        _ = try await appendReport(to: store, operationID: "turn-1")
        let barrier = IntegrationBarrier()
        let integrator = BarrierIntegrator(barrier: barrier)
        let coordinator = AtlasIntegrationCoordinator(store: store, integrator: integrator)

        let flush = Task { try await coordinator.flush() }
        await barrier.waitForEntered(1)
        let late = try await appendReport(to: store, operationID: "turn-2")
        await barrier.release()

        let outcome = try await flush.value
        let receipt = try #require(outcome.receipt)
        #expect(receipt.state.stateVersion == 1)
        #expect(receipt.state.watermark(for: homeID) == 1)
        #expect((await store.pendingReports()).map(\.id) == [late.report.id])
    }

    @Test("one stale compare-and-swap retries exactly once and then commits")
    func oneStaleRetryCommits() async throws {
        let store = try await seededStore()
        _ = try await appendReport(to: store, operationID: "turn-1")
        let integrator = CatalogChurningIntegrator(
            store: store,
            ascendantID: ascendantID,
            churnCount: 1
        )
        let coordinator = AtlasIntegrationCoordinator(store: store, integrator: integrator)

        let outcome = try await coordinator.flush()
        let receipt = try #require(outcome.receipt)
        let diagnostic = try #require(outcome.diagnostic)

        #expect(await integrator.invocationCount() == 2)
        #expect(receipt.state.stateVersion == 1)
        #expect(diagnostic.attempt == 2)
        #expect((await store.registrations()).count == 2)
        #expect((await store.pendingReports()).isEmpty)
    }

    @Test("a second stale failure surfaces without looping")
    func secondStaleFailureSurfaces() async throws {
        let store = try await seededStore()
        _ = try await appendReport(to: store, operationID: "turn-1")
        let integrator = CatalogChurningIntegrator(
            store: store,
            ascendantID: ascendantID,
            churnCount: 2
        )
        let coordinator = AtlasIntegrationCoordinator(store: store, integrator: integrator)

        await #expect(throws: AtlasStoreError.catalogChanged) {
            _ = try await coordinator.flush()
        }
        #expect(await integrator.invocationCount() == 2)
        #expect((await store.snapshot()).stateVersion == 0)
        #expect((await store.pendingReports()).count == 1)
        #expect(!(await coordinator.isFlushing))
    }

    @Test("an observer is silent when there is no work")
    func observerIsSilentWithoutWork() async throws {
        let store = try await seededStore()
        let observer = DiagnosticCollector()
        let coordinator = AtlasIntegrationCoordinator(
            store: store,
            integrator: AtlasNoOpIntegrator(),
            observer: observer
        )

        #expect(try await coordinator.flush() == .noWork)
        #expect(await observer.diagnostics.isEmpty)
    }

    // MARK: - Helpers

    private func seededStore(ascendantID: UUID? = nil) async throws -> InMemoryAtlasStore {
        let store = InMemoryAtlasStore(ascendantID: ascendantID ?? self.ascendantID)
        _ = try await store.register(AscendantShard(
            id: homeID,
            ascendantID: ascendantID ?? self.ascendantID,
            name: "Home"
        ))
        return store
    }

    @discardableResult
    private func appendReport(to store: InMemoryAtlasStore, operationID: String) async throws -> AtlasAppendResult {
        let ascendantID = await store.ascendantID
        return try await store.append(ShardReportDraft(
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
        ))
    }
}

// MARK: - Test doubles

/// A deterministic barrier that lets a test observe integration entry and
/// release it explicitly.
actor IntegrationBarrier {
    private var entered = 0
    private var enterWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func enterAndWait() async {
        entered += 1
        let ready = enterWaiters.filter { entered >= $0.count }
        enterWaiters.removeAll { entered >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
        if isReleased { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForEntered(_ count: Int) async {
        if entered >= count { return }
        await withCheckedContinuation { enterWaiters.append((count, $0)) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

/// An integrator that blocks on a barrier and returns a fixed no-op proposal.
actor BarrierIntegrator: AtlasIntegrator {
    nonisolated let descriptor = AtlasIntegratorDescriptor(identifier: "atlas.barrier", version: "1")

    private let barrier: IntegrationBarrier
    private var invocations = 0

    init(barrier: IntegrationBarrier) {
        self.barrier = barrier
    }

    func integrate(_ request: AtlasIntegrationRequest) async throws -> AtlasIntegrationProposal {
        invocations += 1
        await barrier.enterAndWait()
        return AtlasIntegrationProposal(operations: [.noOp])
    }

    func invocationCount() -> Int { invocations }
}

/// An integrator that mutates the Shard catalog to force a retryable CAS
/// failure on the first `churnCount` integrations.
actor CatalogChurningIntegrator: AtlasIntegrator {
    nonisolated let descriptor = AtlasIntegratorDescriptor(identifier: "atlas.churn", version: "1")

    private let store: InMemoryAtlasStore
    private let ascendantID: UUID
    private var remainingChurns: Int
    private var invocations = 0

    init(store: InMemoryAtlasStore, ascendantID: UUID, churnCount: Int) {
        self.store = store
        self.ascendantID = ascendantID
        self.remainingChurns = churnCount
    }

    func integrate(_ request: AtlasIntegrationRequest) async throws -> AtlasIntegrationProposal {
        invocations += 1
        if remainingChurns > 0 {
            remainingChurns -= 1
            _ = try await store.register(AscendantShard(
                id: AscendantShardID(rawValue: UUID()),
                ascendantID: ascendantID,
                name: "Churn \(invocations)"
            ))
        }
        return AtlasIntegrationProposal(operations: [.noOp])
    }

    func invocationCount() -> Int { invocations }
}

/// Collects accepted-change diagnostics for assertions.
actor DiagnosticCollector: AtlasAcceptedChangeObserver {
    private(set) var diagnostics: [AtlasAcceptedChangeDiagnostic] = []

    func accept(_ diagnostic: AtlasAcceptedChangeDiagnostic) async {
        diagnostics.append(diagnostic)
    }
}
