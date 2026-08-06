// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// Owns the non-blocking narrative capture path in the runner.
///
/// Capture runs after a bounded task completes or an active arc materially
/// changes, validates through GNO-006, and appends accepted entries without
/// delaying or failing the user-visible result. Shutdown deterministically
/// flushes owned capture work.
@MainActor
public final class NarrativeRuntime {
    /// The capture service.
    public let capture: NarrativeCaptureService
    private let store: InMemoryNarrativeStore

    /// Creates a runtime with a default in-memory store and a deterministic
    /// fixture proposer (no credentials or LLM required).
    public init() {
        let store = InMemoryNarrativeStore()
        self.store = store
        self.capture = NarrativeCaptureService(
            store: store,
            proposer: FixtureProposer(),
            validator: NarrativeValidator(
                sensitiveValueMatch: { _ in false },
                existingEntries: { [] }
            ),
            sensitiveValueHandler: { _ in false }
        )
    }

    /// Wires a store that exists before the capture service for tests.
    public init(
        store: InMemoryNarrativeStore,
        proposer: any NarrativeProposer,
        sensitiveValueHandler: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.store = store
        self.capture = NarrativeCaptureService(
            store: store,
            proposer: proposer,
            validator: NarrativeValidator(
                sensitiveValueMatch: sensitiveValueHandler,
                existingEntries: { [] }
            ),
            sensitiveValueHandler: sensitiveValueHandler
        )
    }

    /// Deterministically flushes capture work owned by this runtime.
    public func shutdown() async {
        await capture.shutdown()
    }
}

/// A deterministic, credential-free narrative proposer used by the runner
/// fixture.
private struct FixtureProposer: NarrativeProposer {
    func propose(for input: NarrativeCaptureInput) async -> NarrativeProposal? {
        NarrativeProposal(
            id: NarrativeEntryID(),
            kind: .lesson,
            occurredAt: Date(),
            source: input.source,
            observation: "A bounded task completed.",
            interpretation: "Reusable outcome captured for later turns.",
            lesson: ProposedLesson(summary: "Reuse earlier outcomes in later turns."),
            importance: 0.6,
            confidence: 0.85,
            supportingEpisodes: [],
            isFactStatedSpeculation: false,
            isOverbroadSelfCharacterization: false
        )
    }
}