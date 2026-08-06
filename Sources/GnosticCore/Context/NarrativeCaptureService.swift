// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Captures narrative after bounded tasks (or material arc changes) without
/// delaying or failing the user-visible result, then feeds later turns through
/// GNO-007/GNO-008. Failed tool calls become episodes only when they affect
/// later behavior or leave open threads.
public actor NarrativeCaptureService {
    /// The outcome of a single capture request.
    public struct CaptureOutcome: Sendable, Equatable {
        /// Whether an entry was admitted and appended.
        public let recorded: Bool
        /// The admitted entry identifier, when one was stored.
        public let admittedID: NarrativeEntryID?
        /// Reasons for a rejection, when the proposal was refused.
        public let rejectionReasons: [NarrativeRejectionReason]

        /// The "nothing recorded" outcome.
        public static let notRecorded = CaptureOutcome(
            recorded: false,
            admittedID: nil,
            rejectionReasons: []
        )
    }

    private let store: any NarrativeStore
    private let proposer: any NarrativeProposer
    private let validator: NarrativeValidator
    private let sensitiveValueHandler: @Sendable (String) -> Bool
    private var pendingRequests = 0

    /// Creates a non-blocking capture service with injected dependencies.
    ///
    /// - Parameters:
    ///   - store: The append-only narrative store.
    ///   - proposer: The async proposal boundary.
    ///   - validator: The admission validator (GNO-006).
    ///   - sensitiveValueHandler: Rejects sensitive narrative values.
    public init(
        store: any NarrativeStore,
        proposer: any NarrativeProposer,
        validator: NarrativeValidator,
        sensitiveValueHandler: @escaping @Sendable (String) -> Bool
    ) {
        self.store = store
        self.proposer = proposer
        self.validator = validator
        self.sensitiveValueHandler = sensitiveValueHandler
    }

    /// Captures narrative after a bounded task completes. Runs independently of
    /// the user-visible result: failures in proposal, validation, or storage are
    /// never surfaced to the caller.
    ///
    /// - Parameter input: The completed-task input.
    public func capture(input: NarrativeCaptureInput) async -> CaptureOutcome {
        if input.outcome == .failure, !(await proposer.shouldRecordFailingCall(for: input)) {
            return .notRecorded
        }
        guard let proposal = await proposer.propose(for: input) else {
            return .notRecorded
        }
        guard !sensitiveValueHandler(sensitiveText(of: proposal)) else {
            return .notRecorded
        }
        let state = NarrativeAuthoritativeState(
            timelineIDs: proposal.source.timelineID.map { [$0] } ?? [],
            workspaceIDs: proposal.source.workspaceIDs
        )
        pendingRequests += 1
        defer { pendingRequests -= 1 }
        do {
            let entry = try await validator.validate(proposal, against: state)
            try await store.append(entry)
            return CaptureOutcome(recorded: true, admittedID: entry.id, rejectionReasons: [])
        } catch let rejection as NarrativeRejection {
            return CaptureOutcome(recorded: false, admittedID: nil, rejectionReasons: rejection.reasons)
        } catch {
            return .notRecorded
        }
    }

    /// Awaits quiescence of all in-flight capture requests.
    public func flush() async {
        while pendingRequests > 0 {
            await Task.yield()
        }
    }

    /// Deterministically cancels or flushes owned capture work.
    public func shutdown() async {
        while pendingRequests > 0 {
            await Task.yield()
        }
    }

    /// Produces the textual packet for a later turn from GNO-007 retrieval,
    /// optionally overridden by the authoritative current state.
    public func relevantPacket(
        query: NarrativeRetrievalQuery,
        overridingState: CurrentStatePacket? = nil
    ) async -> NarrativePromptPacket? {
        let retrieval = NarrativeRetrieval(store: store)
        let result = await retrieval.retrieve(query: query, overridingState: overridingState)
        guard let top = result.rankedEntries.first else { return nil }
        let text = [top.interpretation, top.lesson?.summary].compactMap { $0 }.joined(separator: "\n")
        return NarrativePromptPacket(
            text: text,
            appliesToMessageID: top.source.conversation.lastMessageID,
            appliesToNarrativeVersion: 1
        )
    }

    private func sensitiveText(of proposal: NarrativeProposal) -> String {
        [proposal.observation, proposal.interpretation, proposal.lesson?.summary ?? ""]
            .joined(separator: "\n")
    }
}