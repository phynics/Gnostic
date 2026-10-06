// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticPositronicContext

/// A one-shot async gate the tests open to release a curator.
actor CurationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// A deterministic curator for coordinator tests.
actor ProbeContextCurator: ContextCurator {
    nonisolated let version = "probe-v1"

    private let gate: CurationGate?
    private let gateTimelineID: String?
    private let failWith: ContextError?
    private let citeUnknownSource: Bool
    private var concurrent = 0
    private(set) var peakConcurrency = 0
    private(set) var callCount = 0
    private(set) var lastActiveCarry = ContextCarryState()
    private var sequence = 0

    init(
        gate: CurationGate? = nil,
        gateTimelineID: String? = nil,
        failWith: ContextError? = nil,
        citeUnknownSource: Bool = false
    ) {
        self.gate = gate
        self.gateTimelineID = gateTimelineID
        self.failWith = failWith
        self.citeUnknownSource = citeUnknownSource
    }

    func propose(
        episode: ContextEpisode,
        activeCarry: ContextCarryState,
        descriptor: ContextDescriptor
    ) async throws -> ContextProposal {
        concurrent += 1
        peakConcurrency = max(peakConcurrency, concurrent)
        callCount += 1
        lastActiveCarry = activeCarry
        defer { concurrent -= 1 }

        if let failWith { throw failWith }
        if let gate, gateTimelineID == nil || gateTimelineID == episode.timelineID {
            await gate.wait()
        }

        sequence += 1
        let message = episode.messages.first { $0.role == .assistant } ?? episode.messages[0]
        let cited = citeUnknownSource ? "m-not-in-episode" : message.id
        return ContextProposal(
            schemaVersion: descriptor.schemaVersion,
            policyVersion: descriptor.policyVersion,
            synopsis: nil,
            items: [
                ContextCarryItem(
                    id: "item-\(sequence)-\(episode.timelineID)",
                    category: .facts,
                    text: "curated \(message.id)",
                    origin: .assistantAssertion,
                    epistemicStatus: .asserted,
                    citations: [ContextCitation(messageID: cited)]
                )
            ],
            topicLabels: []
        )
    }
}

@Suite("Context curation coordinator")
struct ContextCurationCoordinatorTests {
    @Test("a submission returns without waiting for the curator")
    func submitDoesNotWaitForCurator() async {
        let gate = CurationGate()
        let curator = ProbeContextCurator(gate: gate)
        let (coordinator, _) = makeCoordinator(curator: curator)

        // The curator is gated. Reaching the next line at all proves submit did
        // not wait for it; the partition is active but has accepted nothing.
        await coordinator.submit(episode("tl-1", 0), for: key("tl-1"))

        let state = await coordinator.state(for: key("tl-1"))
        let accepted = await coordinator.diagnostics(for: key("tl-1")).accepted
        #expect(state != .idle)
        #expect(state != .stopping)
        #expect(accepted == 0)

        await gate.open()
        await coordinator.waitUntilIdle(for: key("tl-1"))
        let finished = await coordinator.diagnostics(for: key("tl-1")).accepted
        #expect(finished == 1)
    }

    @Test("one Timeline never runs two curations at once and its queue is bounded")
    func boundedConcurrencyAndQueue() async {
        let gate = CurationGate()
        let curator = ProbeContextCurator(gate: gate)
        let (coordinator, store) = makeCoordinator(curator: curator, maxPending: 2)

        for index in 0..<10 {
            await coordinator.submit(episode("tl-1", index), for: key("tl-1"))
        }
        await gate.open()
        await coordinator.waitUntilIdle(for: key("tl-1"))

        let peak = await curator.peakConcurrency
        let calls = await curator.callCount
        let diagnostics = await coordinator.diagnostics(for: key("tl-1"))
        let accepted = await store.acceptedNodes(for: key("tl-1")).count
        #expect(peak == 1)
        #expect(calls <= 1 + 2)
        #expect(diagnostics.overflowMerges >= 1)
        #expect(accepted >= 1)
    }

    @Test("one Timeline's curation does not block another Timeline")
    func timelinesAreIndependent() async {
        let gate = CurationGate()
        let curator = ProbeContextCurator(gate: gate, gateTimelineID: "tl-a")
        let (coordinator, _) = makeCoordinator(curator: curator)

        await coordinator.submit(episode("tl-a", 0), for: key("tl-a"))
        await coordinator.submit(episode("tl-b", 0), for: key("tl-b"))
        await coordinator.waitUntilIdle(for: key("tl-b"))

        let acceptedB = await coordinator.diagnostics(for: key("tl-b")).accepted
        let acceptedA = await coordinator.diagnostics(for: key("tl-a")).accepted
        #expect(acceptedB == 1)
        #expect(acceptedA == 0)

        await gate.open()
        await coordinator.waitUntilIdle(for: key("tl-a"))
        let finishedA = await coordinator.diagnostics(for: key("tl-a")).accepted
        #expect(finishedA == 1)
    }

    @Test("shutdown fences off a pending write")
    func shutdownFenceDiscardsPendingWork() async {
        let gate = CurationGate()
        let curator = ProbeContextCurator(gate: gate)
        let (coordinator, store) = makeCoordinator(curator: curator)

        await coordinator.submit(episode("tl-1", 0), for: key("tl-1"))
        // Wait until the drain task is inside the gated curator call, so the
        // shutdown fence is exercised on an in-flight curation.
        while await curator.callCount == 0 {
            await Task.yield()
        }
        let shutdown = Task { await coordinator.shutdown() }
        while await coordinator.state(for: key("tl-1")) != .stopping {
            await Task.yield()
        }
        await gate.open()
        await shutdown.value

        let accepted = await store.acceptedNodes(for: key("tl-1"))
        let diagnostics = await coordinator.diagnostics(for: key("tl-1"))
        #expect(accepted.isEmpty)
        #expect(diagnostics.rejectedAfterShutdown == 1)
        #expect(diagnostics.accepted == 0)

        await coordinator.submit(episode("tl-1", 1), for: key("tl-1"))
        await coordinator.waitUntilIdle(for: key("tl-1"))
        let after = await store.acceptedNodes(for: key("tl-1"))
        #expect(after.isEmpty)
    }

    @Test("a curator failure leaves the store untouched")
    func curatorFailureIsContained() async {
        let curator = ProbeContextCurator(failWith: .malformedProposal)
        let (coordinator, store) = makeCoordinator(curator: curator)

        await coordinator.submit(episode("tl-1", 0), for: key("tl-1"))
        await coordinator.waitUntilIdle(for: key("tl-1"))

        let accepted = await store.acceptedNodes(for: key("tl-1"))
        let diagnostics = await coordinator.diagnostics(for: key("tl-1"))
        #expect(accepted.isEmpty)
        #expect(diagnostics.rejected == 1)
        #expect(diagnostics.accepted == 0)
        #expect(diagnostics.lastError == .malformedProposal)
    }

    @Test("the host validator is the authority, not the curator")
    func validatorRejectsUnknownCitation() async {
        let curator = ProbeContextCurator(citeUnknownSource: true)
        let (coordinator, store) = makeCoordinator(curator: curator)

        await coordinator.submit(episode("tl-1", 0), for: key("tl-1"))
        await coordinator.waitUntilIdle(for: key("tl-1"))

        let accepted = await store.acceptedNodes(for: key("tl-1"))
        let diagnostics = await coordinator.diagnostics(for: key("tl-1"))
        #expect(accepted.isEmpty)
        #expect(diagnostics.lastError == .unknownSourceRange)
    }

    @Test("the next episode sees the carry the store accepted")
    func carryThreadsFromTheStore() async {
        let curator = ProbeContextCurator()
        let (coordinator, _) = makeCoordinator(curator: curator)

        await coordinator.submit(episode("tl-1", 0), for: key("tl-1"))
        await coordinator.waitUntilIdle(for: key("tl-1"))
        await coordinator.submit(episode("tl-1", 1), for: key("tl-1"))
        await coordinator.waitUntilIdle(for: key("tl-1"))

        let carry = await curator.lastActiveCarry
        let accepted = await coordinator.diagnostics(for: key("tl-1")).accepted
        #expect(carry.items.map(\.text) == ["curated m-0"])
        #expect(accepted == 2)
    }

    @Test("diagnostics carry counts, never conversation text")
    func diagnosticsArePayloadFree() async {
        let curator = ProbeContextCurator()
        let (coordinator, _) = makeCoordinator(curator: curator)
        await coordinator.submit(episode("tl-1", 0), for: key("tl-1"))
        await coordinator.waitUntilIdle(for: key("tl-1"))

        let rendered = String(describing: await coordinator.diagnostics(for: key("tl-1")))
        #expect(!rendered.contains("curated"))
        #expect(!rendered.contains("m-0"))
    }

    // MARK: Helpers

    private func episode(_ timelineID: String, _ index: Int) -> ContextEpisode {
        ContextEpisode(
            timelineID: timelineID,
            messages: [
                ContextMessage(id: "m-\(index)", role: .assistant, text: "assistant note \(index)")
            ]
        )
    }

    private func key(_ timelineID: String) -> ContextStoreKey {
        ContextStoreKey(ascendantID: "asc-1", timelineID: timelineID)
    }

    private func makeCoordinator(
        curator: any ContextCurator,
        maxPending: Int = 4,
        store: InMemoryContextStore = InMemoryContextStore()
    ) -> (ContextCurationCoordinator, InMemoryContextStore) {
        let coordinator = ContextCurationCoordinator(
            store: store,
            validator: ContextProposalValidator(descriptor: .default),
            curator: curator,
            descriptor: .default,
            maxPendingPerTimeline: maxPending
        )
        return (coordinator, store)
    }
}
