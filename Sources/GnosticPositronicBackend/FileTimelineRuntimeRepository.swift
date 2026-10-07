// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts
import PositronicKit
import GnosticCore

/// A backend-neutral opt-in capability that hands a durable Timeline runtime
/// store to the bundled Positronic adapter.
///
/// The capability keeps the mandatory ``AscendantBackendServices`` contract
/// free of PositronicKit types: the host composes the concrete store in
/// `NodeAssembly` and passes it as an opaque ``AscendantBackendOptionalCapability``.
/// The adapter resolves it by type and falls back to an in-memory repository
/// when the host did not opt in.
struct BackendTimelineStoreCapability: AscendantBackendOptionalCapability {
    /// The durable repository the adapter uses for Timeline history and Turn
    /// transitions.
    let repository: any TimelineRuntimeRepository
    /// The same store projected as the Workspace-binding authority.
    let workspaceBindingRepository: any WorkspaceBindingRepository

    init(store: FileTimelineRuntimeRepository) {
        repository = store
        workspaceBindingRepository = store
    }
}

/// One durable mutation applied to an in-memory reference repository.
///
/// The payload records the *resolved inputs* of a successful mutation, not the
/// resulting state. Replay calls the same in-memory transition with the same
/// inputs, so a file-backed repository inherits the reference implementation's
/// transition semantics exactly and cannot drift from them.
enum JournaledOperation: Codable, Sendable, Equatable {
    struct AdmitTurn: Codable, Sendable {
        let timelineID: UUID
        let requestID: UUID
        let callerIntentFingerprint: String
        let inputMessage: TimelineMessage?
        let executionKind: TurnExecutionKind
        let capturedAgentID: UUID?
        let turnID: UUID
        let now: Date
    }

    struct AdmitRetry: Codable, Sendable {
        let timelineID: UUID
        let previousTurnID: UUID
        let requestID: UUID
        let callerIntentFingerprint: String
        let inputMessage: TimelineMessage?
        let executionKind: TurnExecutionKind
        let capturedAgentID: UUID?
        let turnID: UUID
        let attempt: Int
        let now: Date
    }

    struct CompleteTurn: Codable, Sendable {
        let turnID: UUID
        let outcome: TurnOutcome
        let finalMessage: TimelineMessage?
        let terminalHandle: TurnTerminalHandle?
        let now: Date
    }

    struct InterruptTurn: Codable, Sendable {
        enum Disposition: Codable, Sendable {
            case retryable
            case quarantined(String)

            var repositoryValue: TurnInterruptDisposition {
                switch self {
                case .retryable: .retryable
                case let .quarantined(message): .quarantined(message)
                }
            }
        }

        let turnID: UUID
        let reason: String
        let disposition: Disposition
        let now: Date
    }

    case saveTimeline(TimelineRecord)
    case deleteTimeline(UUID)
    case saveMessage(TimelineMessage)
    case admitTurn(AdmitTurn)
    case admitRetry(AdmitRetry)
    case appendNotice(turnID: UUID, notice: TurnNotice)
    case appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date)
    case beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date)
    case recordProviderRequest(turnID: UUID, modelRoundIndex: Int, correlation: TurnCorrelation?, now: Date)
    case recordToolIntent(RuntimeToolIntent)
    case recordToolResult(RuntimeToolResult, message: TimelineMessage?)
    case completeTurn(CompleteTurn)
    case interruptTurn(InterruptTurn)
    case releaseQuarantine(timelineID: UUID, turnID: UUID, phrase: String, now: Date)
    case saveSummary(TimelineSummary)
    case claim(workspaceID: UUID, timelineID: UUID, now: Date)
    case release(workspaceID: UUID, timelineID: UUID, now: Date)
    case transfer(workspaceID: UUID, sourceTimelineID: UUID, destinationTimelineID: UUID, now: Date)

    /// ``AppendOnlyEventLog`` requires an `Equatable` payload, but the shared
    /// value types it carries (`TimelineMessage`) are not `Equatable`. Compare
    /// canonical JSON instead: it is only used for test-time validation, never
    /// on the production path, and it keeps this payload pinned to the exact
    /// bytes the log frames.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let left = try? canonicalEncoding(lhs), let right = try? canonicalEncoding(rhs) else {
            return false
        }
        return left == right
    }

    private static func canonicalEncoding(_ operation: Self) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(operation)
    }
}

/// A file-backed ``TimelineRuntimeRepository``.
///
/// The repository composes two pieces: an `InMemoryTimelineRuntimeRepository`
/// that owns the live transition rules, and an ``AppendOnlyEventLog`` that
/// records the resolved inputs of every successful mutation. On construction it
/// replays the log into a fresh in-memory repository, so a restarted process
/// observes the same Timeline history and Turn lifecycle as the process that
/// wrote it.
///
/// Durability posture: each mutation first changes in-memory state, then
/// appends its journal record. A journal write that fails leaves live state
/// usable but does not claim the mutation was durable; the caller sees the
/// thrown error and can retry. This mirrors the durable Turn event log posture
/// in ADR 0014.
public actor FileTimelineRuntimeRepository: TimelineRuntimeRepository, WorkspaceBindingRepository, TimelineSummaryStore {
    private let delegate: InMemoryTimelineRuntimeRepository
    private let log: AppendOnlyEventLog<JournaledOperation>

    /// A file-backed repository owns durable history and Turn transitions.
    public nonisolated var isDurable: Bool { true }

    /// Opens (or creates) the log at `fileURL` and replays every durable
    /// mutation into a fresh in-memory reference repository.
    ///
    /// - Throws: The recovery error when the log cannot be read, or the
    ///   transition error when a durable record no longer replays. Construction
    ///   fails closed rather than serving a divergent, partially replayed state.
    public init(fileURL: URL) async throws {
        let log = AppendOnlyEventLog<JournaledOperation>(fileURL: fileURL)
        let delegate = InMemoryTimelineRuntimeRepository(isDurable: true)
        for envelope in try log.recover() {
            try await Self.replay(envelope.payload, into: delegate)
        }
        self.log = log
        self.delegate = delegate
    }

    // MARK: TimelinePersistenceProtocol

    public func saveTimeline(_ timeline: TimelineRecord) async throws {
        try await delegate.saveTimeline(timeline)
        try log.append(.saveTimeline(timeline))
    }

    public func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        try await delegate.fetchTimeline(id: id)
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        try await delegate.fetchAllTimelines(includeArchived: includeArchived)
    }

    public func deleteTimeline(id: UUID) async throws {
        try await delegate.deleteTimeline(id: id)
        try log.append(.deleteTimeline(id))
    }

    public func pruneTimelines(
        olderThan timeInterval: TimeInterval,
        excluding excludedTimelineIDs: [UUID],
        dryRun: Bool
    ) async throws -> Int {
        // Resolve the eligible set here so the journal records exactly the
        // timelines that were deleted. Delegating to the in-memory prune would
        // re-evaluate `Date()` on replay and could select a different set.
        let cutoff = Date().addingTimeInterval(-timeInterval)
        let excluded = Set(excludedTimelineIDs)
        let eligible = try await delegate.fetchAllTimelines(includeArchived: true)
            .filter { !excluded.contains($0.id) && $0.updatedAt < cutoff }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        guard !dryRun else { return eligible.count }
        for timeline in eligible {
            try await delegate.deleteTimeline(id: timeline.id)
            try log.append(.deleteTimeline(timeline.id))
        }
        return eligible.count
    }

    // MARK: TimelineMessageStoreProtocol

    public func saveMessage(_ message: TimelineMessage) async throws {
        try await delegate.saveMessage(message)
        try log.append(.saveMessage(message))
    }

    public func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        try await delegate.fetchMessages(for: timelineID)
    }

    public func deleteMessages(for timelineID: UUID) async throws {
        try await delegate.deleteMessages(for: timelineID)
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await delegate.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }

    public func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        try await delegate.fetchSnapshots(for: timelineID)
    }

    // MARK: Admission

    public func admitTurn(
        timelineID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission {
        let admission = try await delegate.admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            now: now
        )
        // `.joined` and `.replayed` observe an existing Turn; they change no
        // durable state and must not append a second journal record.
        if admission.disposition == .admitted {
            try log.append(.admitTurn(.init(
                timelineID: timelineID,
                requestID: requestID,
                callerIntentFingerprint: callerIntentFingerprint,
                inputMessage: inputMessage,
                executionKind: executionKind,
                capturedAgentID: capturedAgentID,
                turnID: turnID,
                now: now
            )))
        }
        return admission
    }

    public func admitRetry(
        timelineID: UUID,
        previousTurnID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        attempt: Int,
        now: Date
    ) async throws -> TurnAdmission {
        let admission = try await delegate.admitRetry(
            timelineID: timelineID,
            previousTurnID: previousTurnID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
            executionKind: executionKind,
            capturedAgentID: capturedAgentID,
            turnID: turnID,
            attempt: attempt,
            now: now
        )
        if admission.disposition == .admitted {
            try log.append(.admitRetry(.init(
                timelineID: timelineID,
                previousTurnID: previousTurnID,
                requestID: requestID,
                callerIntentFingerprint: callerIntentFingerprint,
                inputMessage: inputMessage,
                executionKind: executionKind,
                capturedAgentID: capturedAgentID,
                turnID: turnID,
                attempt: attempt,
                now: now
            )))
        }
        return admission
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? {
        try await delegate.fetchTurn(id: id)
    }

    public func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord? {
        try await delegate.fetchActiveTurn(for: timelineID)
    }

    public func appendNotice(turnID: UUID, notice: TurnNotice) async throws {
        try await delegate.appendNotice(turnID: turnID, notice: notice)
        try log.append(.appendNotice(turnID: turnID, notice: notice))
    }

    public func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws {
        try await delegate.appendCorrelation(turnID: turnID, correlation: correlation, now: now)
        try log.append(.appendCorrelation(turnID: turnID, correlation: correlation, now: now))
    }

    public func fetchNotices(turnID: UUID) async throws -> [TurnNotice] {
        try await delegate.fetchNotices(turnID: turnID)
    }

    public func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] {
        try await delegate.fetchCorrelations(turnID: turnID)
    }

    // MARK: Ordering barriers

    public func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws {
        try await delegate.beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: now)
        try log.append(.beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: now))
    }

    public func recordProviderRequest(
        turnID: UUID,
        modelRoundIndex: Int,
        correlation: TurnCorrelation?,
        now: Date
    ) async throws {
        try await delegate.recordProviderRequest(
            turnID: turnID,
            modelRoundIndex: modelRoundIndex,
            correlation: correlation,
            now: now
        )
        try log.append(.recordProviderRequest(
            turnID: turnID,
            modelRoundIndex: modelRoundIndex,
            correlation: correlation,
            now: now
        ))
    }

    public func recordToolIntent(_ intent: RuntimeToolIntent) async throws {
        try await delegate.recordToolIntent(intent)
        try log.append(.recordToolIntent(intent))
    }

    public func recordToolResult(_ result: RuntimeToolResult) async throws {
        try await delegate.recordToolResult(result)
        try log.append(.recordToolResult(result, message: nil))
    }

    public func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws {
        try await delegate.recordToolResult(result, message: message)
        try log.append(.recordToolResult(result, message: message))
    }

    public func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent] {
        try await delegate.fetchToolIntents(turnID: turnID)
    }

    public func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult] {
        try await delegate.fetchToolResults(turnID: turnID)
    }

    // MARK: Terminal transitions and recovery

    public func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: TimelineMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) async throws -> TurnRecord {
        let existing = try await delegate.fetchTurn(id: turnID)
        let record = try await delegate.completeTurn(
            turnID: turnID,
            outcome: outcome,
            finalMessage: finalMessage,
            terminalHandle: terminalHandle,
            now: now
        )
        // First-writer-wins: a repeat for an already-terminal Turn changes
        // nothing and must not append a second terminal record.
        if existing?.isTerminal != true {
            try log.append(.completeTurn(.init(
                turnID: turnID,
                outcome: outcome,
                finalMessage: finalMessage,
                terminalHandle: terminalHandle,
                now: now
            )))
        }
        return record
    }

    public func interruptTurn(
        turnID: UUID,
        reason: String,
        disposition: TurnInterruptDisposition,
        now: Date
    ) async throws -> TurnInterruptResult {
        let result = try await delegate.interruptTurn(
            turnID: turnID,
            reason: reason,
            disposition: disposition,
            now: now
        )
        if case .interrupted = result {
            let journaled: JournaledOperation.InterruptTurn.Disposition = switch disposition {
            case .retryable: .retryable
            case let .quarantined(message): .quarantined(message)
            }
            try log.append(.interruptTurn(.init(
                turnID: turnID,
                reason: reason,
                disposition: journaled,
                now: now
            )))
        }
        return result
    }

    public func releaseQuarantine(
        timelineID: UUID,
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation,
        now: Date
    ) async throws -> TurnRecord {
        let record = try await delegate.releaseQuarantine(
            timelineID: timelineID,
            turnID: turnID,
            confirmation: confirmation,
            now: now
        )
        try log.append(.releaseQuarantine(
            timelineID: timelineID,
            turnID: turnID,
            phrase: confirmation.phrase,
            now: now
        ))
        return record
    }

    // MARK: Summary projections

    public func saveSummary(_ summary: TimelineSummary) async throws {
        try await delegate.saveSummary(summary)
        try log.append(.saveSummary(summary))
    }

    public func fetchSummaries(for timelineID: UUID) async throws -> [TimelineSummary] {
        try await delegate.fetchSummaries(for: timelineID)
    }

    // MARK: WorkspaceBindingRepository

    public func claim(
        workspaceID: UUID,
        for timelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        let binding = try await delegate.claim(workspaceID: workspaceID, for: timelineID, now: now)
        try log.append(.claim(workspaceID: workspaceID, timelineID: timelineID, now: now))
        return binding
    }

    public func release(
        workspaceID: UUID,
        from timelineID: UUID,
        now: Date = Date()
    ) async throws {
        try await delegate.release(workspaceID: workspaceID, from: timelineID, now: now)
        try log.append(.release(workspaceID: workspaceID, timelineID: timelineID, now: now))
    }

    public func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        let binding = try await delegate.transfer(
            workspaceID: workspaceID,
            from: sourceTimelineID,
            to: destinationTimelineID,
            now: now
        )
        try log.append(.transfer(
            workspaceID: workspaceID,
            sourceTimelineID: sourceTimelineID,
            destinationTimelineID: destinationTimelineID,
            now: now
        ))
        return binding
    }

    public func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding] {
        try await delegate.bindings(for: timelineID)
    }

    public func timelineID(for workspaceID: UUID) async throws -> UUID? {
        try await delegate.timelineID(for: workspaceID)
    }

    // MARK: Replay

    /// Applies one durable mutation to a fresh reference repository.
    ///
    /// The reference implementation's own idempotency and first-writer-wins
    /// guards make replay of a terminal or duplicate operation a no-op, so the
    /// log does not need to distinguish them.
    private static func replay(
        _ operation: JournaledOperation,
        into delegate: InMemoryTimelineRuntimeRepository
    ) async throws {
        switch operation {
        case let .saveTimeline(timeline):
            try await delegate.saveTimeline(timeline)
        case let .deleteTimeline(id):
            try await delegate.deleteTimeline(id: id)
        case let .saveMessage(message):
            try await delegate.saveMessage(message)
        case let .admitTurn(entry):
            _ = try await delegate.admitTurn(
                timelineID: entry.timelineID,
                requestID: entry.requestID,
                callerIntentFingerprint: entry.callerIntentFingerprint,
                inputMessage: entry.inputMessage,
                executionKind: entry.executionKind,
                capturedAgentID: entry.capturedAgentID,
                turnID: entry.turnID,
                now: entry.now
            )
        case let .admitRetry(entry):
            _ = try await delegate.admitRetry(
                timelineID: entry.timelineID,
                previousTurnID: entry.previousTurnID,
                requestID: entry.requestID,
                callerIntentFingerprint: entry.callerIntentFingerprint,
                inputMessage: entry.inputMessage,
                executionKind: entry.executionKind,
                capturedAgentID: entry.capturedAgentID,
                turnID: entry.turnID,
                attempt: entry.attempt,
                now: entry.now
            )
        case let .appendNotice(turnID, notice):
            try await delegate.appendNotice(turnID: turnID, notice: notice)
        case let .appendCorrelation(turnID, correlation, now):
            try await delegate.appendCorrelation(turnID: turnID, correlation: correlation, now: now)
        case let .beginModelRound(turnID, modelRoundIndex, now):
            try await delegate.beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: now)
        case let .recordProviderRequest(turnID, modelRoundIndex, correlation, now):
            try await delegate.recordProviderRequest(
                turnID: turnID,
                modelRoundIndex: modelRoundIndex,
                correlation: correlation,
                now: now
            )
        case let .recordToolIntent(intent):
            try await delegate.recordToolIntent(intent)
        case let .recordToolResult(result, message):
            if let message {
                try await delegate.recordToolResult(result, message: message)
            } else {
                try await delegate.recordToolResult(result)
            }
        case let .completeTurn(entry):
            _ = try await delegate.completeTurn(
                turnID: entry.turnID,
                outcome: entry.outcome,
                finalMessage: entry.finalMessage,
                terminalHandle: entry.terminalHandle,
                now: entry.now
            )
        case let .interruptTurn(entry):
            _ = try await delegate.interruptTurn(
                turnID: entry.turnID,
                reason: entry.reason,
                disposition: entry.disposition.repositoryValue,
                now: entry.now
            )
        case let .releaseQuarantine(timelineID, turnID, phrase, now):
            _ = try await delegate.releaseQuarantine(
                timelineID: timelineID,
                turnID: turnID,
                confirmation: QuarantineReleaseConfirmation(phrase: phrase),
                now: now
            )
        case let .saveSummary(summary):
            try await delegate.saveSummary(summary)
        case let .claim(workspaceID, timelineID, now):
            _ = try await delegate.claim(workspaceID: workspaceID, for: timelineID, now: now)
        case let .release(workspaceID, timelineID, now):
            try await delegate.release(workspaceID: workspaceID, from: timelineID, now: now)
        case let .transfer(workspaceID, sourceTimelineID, destinationTimelineID, now):
            _ = try await delegate.transfer(
                workspaceID: workspaceID,
                from: sourceTimelineID,
                to: destinationTimelineID,
                now: now
            )
        }
    }
}
