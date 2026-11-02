// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// The ledger's classification of one identified Turn admission.
///
/// Only ``new`` may run backend work. Every other case answers the request
/// from the ledger without starting the backend.
internal enum TurnLedgerAdmission: Sendable, Equatable {
    /// The identity was journaled as started. The caller owns the Turn.
    case new
    /// The identity is admitted and has no outcome yet.
    case inFlight
    /// The Turn has a terminal outcome to replay.
    case replay(TurnTerminalOutcome)
    /// The identity was admitted with a different message.
    case conflict
    /// The identity was admitted but its outcome cannot be replayed. This covers
    /// a failed recovered Turn, a truncated outcome, and an identity whose
    /// outcome was evicted.
    case unavailable
    /// The identity is new, but the caller reported that another Turn is active
    /// on its Timeline. Nothing was admitted or journaled.
    case busy
}

/// A terminal outcome of one identified Turn, as committed in this process.
internal enum TurnTerminalOutcome: Sendable, Equatable {
    case succeeded(text: String)
    case failed(AscendantTurnError)
}

/// The outcome retained for one entry. Live outcomes keep the full result for
/// this process; recovered outcomes keep only what the journal stored.
fileprivate enum RetainedOutcome: Sendable, Equatable {
    case live(TurnTerminalOutcome)
    case recovered(TurnJournalOutcome)
}

/// Keeps bounded identified-turn updates for one serve lifetime. It never
/// stores prompt text or tool arguments beyond the bounded update payload.
/// Live events use a bounded best-effort buffer; replay is authoritative recovery.
public actor AscendantTurnUpdateStore {
    public enum Error: Swift.Error, Sendable, Equatable, LocalizedError {
        case capacityExceeded

        public var errorDescription: String? {
            "identified turn update retention capacity is full of active turns"
        }
    }

    public struct Event: Codable, Sendable, Equatable {
        public let protocolMajor: Int
        public let timelineID: UUID
        public let clientTurnID: String
        public let update: AscendantTurnUpdate

        public init(protocolMajor: Int = GnosticProtocol.currentMajor, timelineID: UUID, clientTurnID: String, update: AscendantTurnUpdate) {
            self.protocolMajor = protocolMajor
            self.timelineID = timelineID
            self.clientTurnID = clientTurnID
            self.update = update
        }

        private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID, update }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(protocolMajor, forKey: .protocolMajor)
            try container.encode(timelineID, forKey: .timelineID)
            try container.encode(try GnosticWirePayload.canonicalClientTurnID(clientTurnID), forKey: .clientTurnID)
            try container.encode(update, forKey: .update)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
            timelineID = try container.decode(UUID.self, forKey: .timelineID)
            clientTurnID = try GnosticWirePayload.canonicalClientTurnID(
                container.decode(String.self, forKey: .clientTurnID)
            )
            update = try container.decode(AscendantTurnUpdate.self, forKey: .update)
        }
    }

    private struct Key: Hashable, Sendable {
        let timelineID: UUID
        let clientTurnID: String
    }

    /// An ID that has passed the wire validator. Internal update producers use
    /// this seam so an impossible validation failure cannot be swallowed.
    internal struct ValidatedClientTurnID: Sendable, Hashable {
        let rawValue: String
    }

    private struct Entry: Sendable {
        var updates: [AscendantTurnUpdate]
        var nextSequence: Int
        var bytes: Int
        var terminal: Bool
        var finished: Bool
        var compacted: Bool
        var messageDigest: String?
        /// True when the entry was rebuilt from the journal rather than admitted here.
        var recovered: Bool = false
        var outcome: RetainedOutcome? = nil
    }

    private let maxEvents: Int
    private let maxBytes: Int
    private let maxEntries: Int
    private let eventBufferCapacity: Int
    /// The journal is compacted once its on-disk size exceeds this bound.
    /// Zero or less disables compaction.
    private let maxJournalBytes: Int
    private let timelineJournals: TimelineJournalStore?
    private var entries: [Key: Entry] = [:]
    private var entryOrder: [Key] = []
    private var persistingOutcomes: Set<Key> = []
    private var journal: DurableReplayJournal<TurnEventRecord>?
    private let completedCapacity: Int
    private let identityCapacity: Int
    /// Admitted identities and their message digests. Bounded by
    /// ``identityCapacity`` and never evicted, so an identity whose entry was
    /// evicted or never recovered can never rerun.
    private var identityDigests: [Key: String] = [:]
    /// The Runtime message identifiers that confirmed prompts bound to their
    /// Turns, kept until the Turn's outcome is journaled.
    private var boundMessageIDs: [Key: String] = [:]

    internal var retainedStateCounts: (entries: Int, bytes: Int) {
        (entries.count, entries.values.reduce(0) { $0 + $1.bytes })
    }

    /// Identity and outcome counts for the Turn ledger. `retired` counts
    /// admitted identities whose entry was evicted.
    internal var retainedIdentityCounts: (identities: Int, outcomes: Int, retired: Int, outcomeBytes: Int) {
        var outcomes = 0
        var bytes = 0
        for entry in entries.values {
            guard let outcome = entry.outcome else { continue }
            outcomes += 1
            bytes += Self.outcomeBytes(outcome)
        }
        let retired = identityDigests.keys.reduce(0) { $0 + (entries[$1] == nil ? 1 : 0) }
        return (identityDigests.count, outcomes, retired, bytes)
    }

    /// The configured bounds for admitted identities and retained outcomes.
    internal var admissionCapacities: (identities: Int, completed: Int) {
        (identityCapacity, completedCapacity)
    }
    internal var requiresDurableTimelineAdmission: Bool { timelineJournals != nil }
    private let eventStream: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    public init(
        maxEvents: Int = 1_024,
        maxBytes: Int = 1_048_576,
        maxEntries: Int = 256,
        eventBufferCapacity: Int = 256,
        maxJournalBytes: Int = AscendantTurnUpdateStore.defaultMaxJournalBytes,
        completedCapacity: Int = 256,
        identityCapacity: Int = AscendantTurnUpdateStore.defaultIdentityCapacity,
        timelineJournals: TimelineJournalStore? = nil
    ) {
        // Compacted replay needs room for both a snapshot and the newest (often
        // terminal) update.
        self.maxEvents = max(2, maxEvents)
        self.maxBytes = max(256, maxBytes)
        self.maxEntries = max(1, maxEntries)
        self.eventBufferCapacity = max(1, eventBufferCapacity)
        self.maxJournalBytes = max(0, maxJournalBytes)
        self.timelineJournals = timelineJournals
        self.completedCapacity = max(1, completedCapacity)
        self.identityCapacity = max(1, identityCapacity)
        (eventStream, eventContinuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(self.eventBufferCapacity)
        )
    }

    /// The default on-disk bound for the durable Turn event log.
    public static let defaultMaxJournalBytes = 4 * 1_048_576

    /// The default bound on admitted identified Turns for one serve lifetime.
    public static let defaultIdentityCapacity = 1_024

    /// The most assistant text a journaled outcome keeps. It matches the
    /// bounded update payload, so a longer outcome replays as unavailable.
    private static let maxJournaledTextBytes = 800
    /// The most text one update holds. Longer assistant text continues in the
    /// next update, so this bounds an update and not the text a client receives.
    private static let maxAssistantTextBytes = 800
    /// Ends text that retention cut, so a client can tell it is incomplete.
    private static let truncationMarker = AscendantTurnUpdate.truncationMarker

    func events() -> AsyncStream<Event> { eventStream }

    func finish() {
        eventContinuation.finish()
    }

    /// Enables durable journaling at `url` and rebuilds retained turns from the
    /// records already on disk.
    ///
    /// Call before the first `start`. Recovery replays the bounded updates that
    /// were journaled, so a restarted process sees the same replay ledger.
    public func enableDurability(at url: URL) throws {
        let candidate = DurableReplayJournal<TurnEventRecord>(fileURL: url)
        try candidate.recover { try applyJournalRecord($0) }
        journal = candidate
        compactJournalIfNeeded()
    }

    private func applyJournalRecord(_ record: TurnEventRecord) throws {
        let clientTurnID = ValidatedClientTurnID(rawValue: record.clientTurnID)
        let key = Key(timelineID: record.timelineID, clientTurnID: record.clientTurnID)
        do {
            switch record.event {
            case .started(let messageDigest):
                recoverIdentity(key, messageDigest: messageDigest)
                guard entries[key] == nil else { return }
                try insert(key: key, timelineID: record.timelineID, messageDigest: messageDigest, recovered: true)
            case .update(let update):
                try applyRecoveredUpdate(timelineID: record.timelineID, clientTurnID: clientTurnID, update: update)
            case .finished:
                finish(timelineID: record.timelineID, clientTurnID: clientTurnID)
            case .outcome(let outcome):
                applyRecoveredOutcome(key, outcome)
            case .checkpoint(let snapshot):
                try applyCheckpoint(snapshot, timelineID: record.timelineID, clientTurnID: clientTurnID)
            }
        } catch Error.capacityExceeded {
            // The journal outgrew the live retention bound. This is a
            // deterministic skip, not a recovery failure: the journal may
            // legitimately hold more than the live bound. Every other error
            // surfaces to `enableDurability` so silent partial recovery cannot
            // be reported as success.
        }
    }

    /// Restores an admitted identity's digest. Recovery records identities even
    /// when their entries are skipped, so a skipped Turn still never reruns.
    private func recoverIdentity(_ key: Key, messageDigest: String?) {
        guard let messageDigest, identityDigests[key] == nil, identityDigests.count < identityCapacity else {
            return
        }
        identityDigests[key] = messageDigest
    }

    private func applyRecoveredOutcome(_ key: Key, _ outcome: TurnJournalOutcome) {
        guard var entry = entries[key] else { return }
        entry.outcome = .recovered(outcome)
        entry.terminal = true
        entry.finished = true
        entries[key] = entry
    }

    private func journalRecord(_ record: TurnEventRecord) throws {
        try journal?.append(record)
        compactJournalIfNeeded()
    }

    /// Replaces the journal with one checkpoint per retained Turn once it
    /// exceeds ``maxJournalBytes``.
    ///
    /// Compaction keeps `recover()` semantics: a checkpoint carries the same
    /// bounded state recovery would rebuild from the records it supersedes, so
    /// a restarted store sees the same ledger. The rewrite is skipped when it
    /// would not shrink the file, which keeps a misconfigured bound from
    /// rewriting on every append.
    private func compactJournalIfNeeded() {
        guard let journal, maxJournalBytes > 0 else { return }
        guard let currentBytes = try? journal.byteCount(),
              currentBytes > UInt64(maxJournalBytes)
        else { return }
        let records = checkpointRecords()
        guard !records.isEmpty, let projectedBytes = Self.encodedSize(records),
              projectedBytes < Int(currentBytes)
        else { return }
        try? journal.replaceAll(with: records)
    }

    /// One checkpoint per retained Turn, in retention order, preceded by a
    /// started/finished pair for each retired identity. The pair keeps the
    /// identity's digest across compaction without retaining any state for it.
    private func checkpointRecords() -> [TurnEventRecord] {
        var records: [TurnEventRecord] = []
        for (key, digest) in identityDigests where entries[key] == nil {
            records.append(TurnEventRecord(
                timelineID: key.timelineID,
                clientTurnID: key.clientTurnID,
                event: .started(messageDigest: digest)
            ))
            records.append(TurnEventRecord(
                timelineID: key.timelineID,
                clientTurnID: key.clientTurnID,
                event: .finished
            ))
        }
        records += entryOrder.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return TurnEventRecord(
                timelineID: key.timelineID,
                clientTurnID: key.clientTurnID,
                event: .checkpoint(TurnJournalCheckpoint(
                    messageDigest: entry.messageDigest,
                    nextSequence: entry.nextSequence,
                    updates: entry.updates,
                    compacted: entry.compacted,
                    terminal: entry.terminal,
                    finished: entry.finished,
                    outcome: Self.journaledOutcome(entry.outcome)
                ))
            )
        }
        return records
    }

    /// Replaces one retained Turn's state with a compaction checkpoint.
    private func applyCheckpoint(
        _ snapshot: TurnJournalCheckpoint,
        timelineID: UUID,
        clientTurnID: ValidatedClientTurnID
    ) throws {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        recoverIdentity(key, messageDigest: snapshot.messageDigest)
        if entries[key] == nil {
            evictFinishedEntriesIfNeeded(for: key)
            guard entries.count < maxEntries else { throw Error.capacityExceeded }
        }
        entries[key] = Entry(
            updates: snapshot.updates,
            nextSequence: snapshot.nextSequence,
            bytes: snapshot.updates.reduce(0) { $0 + Self.encodedSize($1) },
            terminal: snapshot.terminal,
            finished: snapshot.finished,
            compacted: snapshot.compacted,
            messageDigest: snapshot.messageDigest,
            recovered: true,
            outcome: snapshot.outcome.map { RetainedOutcome.recovered($0) }
        )
        touch(key)
        evictIfNeeded()
    }

    public func start(timelineID: UUID, clientTurnID: String, message: String? = nil) throws {
        let validated = try validatedClientTurnID(clientTurnID)
        try start(timelineID: timelineID, clientTurnID: validated, message: message)
    }

    internal func validatedClientTurnID(_ value: String) throws -> ValidatedClientTurnID {
        ValidatedClientTurnID(rawValue: try GnosticWirePayload.canonicalClientTurnID(value))
    }

    internal func start(timelineID: UUID, clientTurnID: ValidatedClientTurnID, message: String? = nil) throws {
        try start(timelineID: timelineID, clientTurnID: clientTurnID, messageDigest: message.map { Self.messageDigest($0) })
    }

    internal func start(timelineID: UUID, clientTurnID: ValidatedClientTurnID, messageDigest: String?) throws {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        guard entries[key] == nil else { return }
        // A retired identity never reopens with a digest: its outcome was evicted.
        if messageDigest != nil, identityDigests[key] != nil { return }
        try insert(key: key, timelineID: timelineID, messageDigest: messageDigest, recovered: false)
    }

    /// Admits one identified Turn, or classifies a retry against the ledger.
    ///
    /// ``TurnLedgerAdmission/new`` means the identity was journaled as started and the
    /// caller may run the backend. Every other case answers the request without
    /// running the backend, so an admitted identity never reruns.
    ///
    /// - Parameter admitNew: Whether the Timeline can take a new Turn. When it
    ///   cannot, a request for an identity the ledger does not know is answered
    ///   ``TurnLedgerAdmission/busy`` without admitting or journaling it. A retry
    ///   of a known identity is classified as usual, because it never starts a
    ///   second Turn.
    internal func admit(
        timelineID: UUID,
        clientTurnID: ValidatedClientTurnID,
        message: String,
        admitNew: Bool = true
    ) async throws -> TurnLedgerAdmission {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        let digest = Self.messageDigest(message)
        if let admitted = identityDigests[key] {
            guard admitted == digest else { return .conflict }
            guard let entry = entries[key] else { return .unavailable }
            return Self.admission(for: entry, key: key)
        }
        // An entry without an admitted identity came from a non-admitted path.
        // Admission never adopts it, so it fails closed.
        guard entries[key] == nil else { return .unavailable }
        if let timelineJournals {
            let journal = try await timelineJournals.journal(for: timelineID)
            let records = try await journal.replay()
            var admittedTurns = 0
            var lastSequence = 0
            var prior: (digest: String, outcome: TimelineTurnTerminalOutcome?)?
            for record in records where record.timelineID == timelineID {
                switch record.payload {
                case let .turnAdmitted(admittedID, admissionDigest, turnSequence, _, _):
                    admittedTurns += 1
                    lastSequence = max(lastSequence, turnSequence)
                    if admittedID == key.clientTurnID { prior = (admissionDigest, nil) }
                case let .turnCompleted(completedID, outcome, _) where completedID == key.clientTurnID:
                    if let admitted = prior { prior = (admitted.digest, outcome) }
                default:
                    break
                }
            }
            if let prior {
                guard prior.digest == digest else { return .conflict }
                return Self.recoveredAdmission(for: key, outcome: prior.outcome)
            }
            guard admitNew else { return .busy }
            // The owning Timeline journal commits admission before the
            // bounded replay ledger. Failure or a crash after this point can
            // lose availability, but can never dispatch an unjournaled Turn.
            try await journal.append(.turnAdmitted(
                clientTurnID: key.clientTurnID,
                admissionDigest: digest,
                turnSequence: max(lastSequence, admittedTurns) + 1,
                acpVersionTag: ACPv2Protocol.versionTag,
                prompt: Self.timelineAdmissionPrompt(message)
            ))
        }
        guard admitNew else { return .busy }
        try insert(key: key, timelineID: timelineID, messageDigest: digest, recovered: false)
        return .new
    }

    /// Classifies an identity that the Timeline journal admitted before this
    /// process started. The journal holds the prompt and the outcome kind but not
    /// the assistant text, so a finished Turn cannot replay its result.
    ///
    /// A Turn with no completion record, or one recorded `insertionUnknown`, may
    /// or may not have been inserted. It is never dispatched again.
    private static func recoveredAdmission(
        for key: Key,
        outcome: TimelineTurnTerminalOutcome?
    ) -> TurnLedgerAdmission {
        switch outcome {
        case nil, .insertionUnknown?:
            return .replay(.failed(.insertionUnknown(timelineID: key.timelineID, clientTurnID: key.clientTurnID)))
        case .cancelled?:
            return .replay(.failed(.cancelled(timelineID: key.timelineID, clientTurnID: key.clientTurnID)))
        case .completed?, .endedUnspecified?, .failed?, .unavailable?:
            return .unavailable
        }
    }

    /// Binds an admitted Turn to the Runtime's message identifier. The outcome
    /// record carries it. An identifier for a Turn that already ended is ignored.
    internal func bindMessageID(timelineID: UUID, clientTurnID: ValidatedClientTurnID, messageID: String) {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        guard entries[key]?.outcome == nil else { return }
        boundMessageIDs[key] = messageID
    }

    /// Records the terminal outcome of one admitted Turn and appends the
    /// bounded terminal update it replays as. The outcome is the replay record:
    /// a restarted node answers the same identity from it.
    ///
    /// This is the one ledger call the runtime makes to terminalize a Turn. It
    /// derives the terminal update the wire adapter used to write from its catch
    /// arms. The append is idempotent because ``append`` returns the retained
    /// terminal update once an entry holds one, so a terminal the backend already
    /// emitted is never duplicated.
    internal func recordOutcome(
        timelineID: UUID,
        clientTurnID: ValidatedClientTurnID,
        outcome: TurnTerminalOutcome
    ) async throws {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        guard entries[key]?.outcome == nil,
              persistingOutcomes.insert(key).inserted else { return }
        defer {
            persistingOutcomes.remove(key)
            boundMessageIDs.removeValue(forKey: key)
        }
        if let timelineJournals {
            let journal = try await timelineJournals.journal(for: timelineID)
            try await journal.append(.turnCompleted(
                clientTurnID: clientTurnID.rawValue,
                outcome: Self.timelineOutcome(outcome, endedUnspecified: endedUnspecified(key)),
                messageID: boundMessageIDs[key]
            ))
        }
        guard var entry = entries[key], entry.outcome == nil else { return }
        entry.outcome = .live(outcome)
        entry.terminal = true
        entry.finished = true
        entries[key] = entry
        touch(key)
        enforceCompletedCapacity()
        evictIfNeeded()
        // A dropped outcome record leaves the identity without an outcome.
        // Recovery then reports it unavailable rather than rerunning it.
        try? journalRecord(TurnEventRecord(
            timelineID: timelineID,
            clientTurnID: key.clientTurnID,
            event: .outcome(Self.journalOutcome(outcome))
        ))
        appendTerminalUpdate(timelineID: timelineID, clientTurnID: clientTurnID, outcome: outcome)
    }

    /// Commits permission before the coordinator publishes or releases it.
    internal func recordPermissionDecision(
        request: BackendPermissionRequest, decision: AscendantPermissionDecision
    ) async throws {
        guard let timelineJournals else { return }
        let value: String
        switch decision {
        case .approved: value = "approved"
        case .denied: value = "denied"
        case .unavailable: value = "unavailable"
        }
        try await TimelineJournalRecorder(journals: timelineJournals).appendPermissionDecision(
            timelineID: request.timelineID, clientTurnID: request.clientTurnID,
            correlationID: request.correlationID, decision: value, approved: decision.isApproved
        )
    }

    /// Whether the Runtime ended the Turn with an idle update that carried no stop
    /// reason. The backend marks that on the Turn's terminal completion update.
    private func endedUnspecified(_ key: Key) -> Bool {
        guard let terminal = entries[key]?.updates.last(where: \.terminal) else { return false }
        return terminal.kind == AscendantTurnUpdateKind.completion.rawValue
            && terminal.reasonCode == TimelineTurnTerminalOutcome.endedUnspecified.rawValue
    }

    private static func timelineOutcome(
        _ outcome: TurnTerminalOutcome,
        endedUnspecified: Bool
    ) -> TimelineTurnTerminalOutcome {
        switch outcome {
        case .succeeded:
            endedUnspecified ? .endedUnspecified : .completed
        case let .failed(error):
            switch error {
            case .cancelled: .cancelled
            case .insertionUnknown: .insertionUnknown
            default: .failed
            }
        }
    }

    /// Appends the bounded update a committed outcome replays as. A capacity
    /// rejection is swallowed: the outcome is already the replay record, and the
    /// identity never reruns, so a missing update must not fail the Turn.
    private func appendTerminalUpdate(
        timelineID: UUID,
        clientTurnID: ValidatedClientTurnID,
        outcome: TurnTerminalOutcome
    ) {
        switch outcome {
        case let .succeeded(text):
            let streamed = replay(timelineID: timelineID, clientTurnID: clientTurnID)
                .updates
                .contains(where: \.carriesAssistantText)
            if !streamed {
                _ = try? append(
                    timelineID: timelineID,
                    clientTurnID: clientTurnID,
                    kind: AscendantTurnUpdateKind.assistantText.rawValue,
                    text: text
                )
            }
            _ = try? append(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                kind: AscendantTurnUpdateKind.completion.rawValue,
                text: text,
                terminal: true
            )
        case let .failed(error):
            let kind: AscendantTurnUpdateKind = if case .cancelled = error { .cancellation } else { .error }
            _ = try? append(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                kind: kind.rawValue,
                text: error.publicMessage,
                terminal: true,
                reasonCode: error.reasonCode,
                statusCode: error.statusCode,
                retryable: error.retryable
            )
        }
    }

    /// Opens an entry for a new admission or a recovered start. The identity is
    /// recorded first, and only when it has room. The entry may still be refused
    /// by the entry bound, which leaves the identity in place.
    private func insert(key: Key, timelineID: UUID, messageDigest: String?, recovered: Bool) throws {
        if messageDigest != nil, identityDigests[key] == nil {
            guard identityDigests.count < identityCapacity else { throw Error.capacityExceeded }
        }
        evictFinishedEntriesIfNeeded(for: key)
        guard entries.count < maxEntries else { throw Error.capacityExceeded }
        if let messageDigest, identityDigests[key] == nil {
            identityDigests[key] = messageDigest
        }
        entries[key] = Entry(
            updates: [], nextSequence: 1, bytes: 0, terminal: false, finished: false, compacted: false,
            messageDigest: messageDigest, recovered: recovered
        )
        touch(key)
        evictIfNeeded()
        try journalRecord(TurnEventRecord(
            timelineID: timelineID,
            clientTurnID: key.clientTurnID,
            event: .started(messageDigest: messageDigest)
        ))
    }

    /// Keeps at most ``completedCapacity`` retained outcomes. An evicted entry
    /// keeps its identity, so it replays as unavailable and never reruns.
    private func enforceCompletedCapacity() {
        var completed = entries.values.reduce(0) { $0 + ($1.outcome == nil ? 0 : 1) }
        while completed > completedCapacity,
              let oldest = entryOrder.first(where: { entries[$0]?.outcome != nil }) {
            entryOrder.removeAll { $0 == oldest }
            entries.removeValue(forKey: oldest)
            completed -= 1
        }
    }

    private static func admission(for entry: Entry, key: Key) -> TurnLedgerAdmission {
        let insertionUnknown = AscendantTurnError.insertionUnknown(
            timelineID: key.timelineID, clientTurnID: key.clientTurnID
        )
        switch entry.outcome {
        case nil:
            // A recovered start without an outcome may have lost the prompt
            // response with the process. It never dispatches again.
            return entry.recovered ? .replay(.failed(insertionUnknown)) : .inFlight
        case let .live(outcome)?:
            return .replay(outcome)
        case let .recovered(journaled)?:
            if !journaled.succeeded, journaled.reasonCode == insertionUnknown.reasonCode {
                return .replay(.failed(insertionUnknown))
            }
            guard journaled.succeeded, !journaled.truncated, let text = journaled.text else {
                return .unavailable
            }
            return .replay(.succeeded(text: text))
        }
    }

    private static func journalOutcome(_ outcome: TurnTerminalOutcome) -> TurnJournalOutcome {
        switch outcome {
        case let .succeeded(text):
            let bounded = GnosticWirePayload.prefix(text, maximumBytes: maxJournaledTextBytes)
            return TurnJournalOutcome(succeeded: true, text: bounded, truncated: bounded != text)
        case let .failed(error):
            // Only the reason that changes what a retry may do is kept, so a
            // restarted ledger still answers insertionUnknown without a rerun.
            var keptReason: String?
            if case .insertionUnknown = error { keptReason = error.reasonCode }
            return TurnJournalOutcome(succeeded: false, text: nil, truncated: false, reasonCode: keptReason)
        }
    }

    private static func journaledOutcome(_ outcome: RetainedOutcome?) -> TurnJournalOutcome? {
        switch outcome {
        case nil:
            return nil
        case let .live(live)?:
            return journalOutcome(live)
        case let .recovered(journaled)?:
            return journaled
        }
    }

    private static func outcomeBytes(_ outcome: RetainedOutcome) -> Int {
        switch outcome {
        case let .live(.succeeded(text)):
            return text.utf8.count + 96
        case let .live(.failed(error)):
            return error.reasonCode.utf8.count + error.localizedDescription.utf8.count + 64
        case let .recovered(journaled):
            return (journaled.text?.utf8.count ?? 0) + 96
        }
    }

    public func finish(timelineID: UUID, clientTurnID: String) throws {
        let validated = try validatedClientTurnID(clientTurnID)
        finish(timelineID: timelineID, clientTurnID: validated)
    }

    internal func finish(timelineID: UUID, clientTurnID: ValidatedClientTurnID) {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        guard var entry = entries[key] else { return }
        entry.finished = true
        entries[key] = entry
        evictIfNeeded()
        // The finish marker is an eviction hint. A dropped marker costs only a
        // recovered entry that stays unfinished until it is finished again.
        try? journalRecord(TurnEventRecord(
            timelineID: timelineID,
            clientTurnID: clientTurnID.rawValue,
            event: .finished
        ))
    }

    @discardableResult
    public func append(
        timelineID: UUID,
        clientTurnID: String,
        kind: String,
        text: String? = nil,
        toolState: AscendantToolState? = nil,
        permissionState: AscendantPermissionState? = nil,
        terminal: Bool = false,
        reasonCode: String? = nil,
        statusCode: Int? = nil,
        retryable: Bool? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) throws -> AscendantTurnUpdate {
        let validated = try validatedClientTurnID(clientTurnID)
        return try append(timelineID: timelineID, clientTurnID: validated, kind: kind, text: text, toolState: toolState, permissionState: permissionState, terminal: terminal, reasonCode: reasonCode, statusCode: statusCode, retryable: retryable, protocolMajor: protocolMajor)
    }

    internal func append(
        timelineID: UUID,
        clientTurnID: ValidatedClientTurnID,
        kind: String,
        text: String? = nil,
        toolState: AscendantToolState? = nil,
        permissionState: AscendantPermissionState? = nil,
        terminal: Bool = false,
        reasonCode: String? = nil,
        statusCode: Int? = nil,
        retryable: Bool? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) throws -> AscendantTurnUpdate {
        let limit = min(maxBytes / 2, 1_200)
        // Assistant text longer than one update continues in the next one, so a
        // client assembles all of it. Other text fields are diagnostics.
        if kind == AscendantTurnUpdateKind.assistantText.rawValue, !terminal, toolState == nil,
           permissionState == nil, let text {
            let pieces = Self.assistantTextPieces(text, kind: kind, maxBytes: limit)
            if pieces.count > 1 {
                var last: AscendantTurnUpdate?
                for piece in pieces {
                    last = try appendBounded(
                        timelineID: timelineID, clientTurnID: clientTurnID, kind: kind, text: piece,
                        toolState: nil, permissionState: nil, terminal: false, reasonCode: reasonCode,
                        statusCode: statusCode, retryable: retryable, protocolMajor: protocolMajor, maxBytes: limit
                    )
                }
                if let last { return last }
            }
        }
        return try appendBounded(
            timelineID: timelineID, clientTurnID: clientTurnID, kind: kind, text: text,
            toolState: toolState, permissionState: permissionState, terminal: terminal, reasonCode: reasonCode,
            statusCode: statusCode, retryable: retryable, protocolMajor: protocolMajor, maxBytes: limit
        )
    }

    private func appendBounded(
        timelineID: UUID,
        clientTurnID: ValidatedClientTurnID,
        kind: String,
        text: String?,
        toolState: AscendantToolState?,
        permissionState: AscendantPermissionState?,
        terminal: Bool,
        reasonCode: String?,
        statusCode: Int?,
        retryable: Bool?,
        protocolMajor: Int,
        maxBytes limit: Int
    ) throws -> AscendantTurnUpdate {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        if entries[key] == nil {
            evictFinishedEntriesIfNeeded(for: key)
            guard entries.count < maxEntries else { throw Error.capacityExceeded }
        }
        var entry = entries[key] ?? Entry(updates: [], nextSequence: 1, bytes: 0, terminal: false, finished: false, compacted: false, messageDigest: nil)
        if entry.terminal, let terminalUpdate = entry.updates.last(where: \.terminal) {
            return terminalUpdate
        }
        let update = Self.bounded(
            AscendantTurnUpdate(
                sequence: entry.nextSequence,
                kind: kind,
                text: text,
                toolState: toolState,
                permissionState: permissionState,
                terminal: terminal,
                reasonCode: reasonCode,
                statusCode: statusCode,
                retryable: retryable,
                protocolMajor: protocolMajor
            ),
            maxBytes: limit
        )
        apply(update, into: &entry)
        entries[key] = entry
        touch(key)
        evictIfNeeded()
        eventContinuation.yield(Event(protocolMajor: protocolMajor, timelineID: timelineID, clientTurnID: clientTurnID.rawValue, update: update))
        try journalRecord(TurnEventRecord(
            protocolMajor: protocolMajor,
            timelineID: timelineID,
            clientTurnID: clientTurnID.rawValue,
            event: .update(update)
        ))
        return update
    }

    /// Applies one bounded update to an entry and compacts if needed.
    private func apply(_ update: AscendantTurnUpdate, into entry: inout Entry) {
        entry.nextSequence = max(entry.nextSequence, update.sequence + 1)
        entry.updates.append(update)
        entry.bytes += Self.encodedSize(update)
        entry.terminal = entry.terminal || update.terminal
        compactIfNeeded(&entry)
    }

    private func compactIfNeeded(_ entry: inout Entry) {
        guard entry.updates.count > maxEvents || entry.bytes > maxBytes else { return }
        var snapshotText = ""
        var snapshotToolStates: [AscendantToolState] = []
        var snapshotPermissionStates: [AscendantPermissionState] = []
        var snapshotSequence = 0
        // Reserve half of the byte budget for the accumulated snapshot.
        while entry.updates.count >= maxEvents || entry.bytes > maxBytes / 2 {
            guard entry.updates.count > 1 else { break }
            let removed = entry.updates.removeFirst()
            entry.bytes -= Self.encodedSize(removed)
            snapshotSequence = max(snapshotSequence, removed.sequence)
            if removed.carriesAssistantText {
                snapshotText += removed.text ?? ""
            }
            if let toolState = removed.toolState {
                Self.upsert(toolState, into: &snapshotToolStates)
            }
            for toolState in removed.toolStates {
                Self.upsert(toolState, into: &snapshotToolStates)
            }
            if let permissionState = removed.permissionState {
                Self.upsert(permissionState, into: &snapshotPermissionStates)
            }
            for permissionState in removed.permissionStates {
                Self.upsert(permissionState, into: &snapshotPermissionStates)
            }
            entry.compacted = true
        }
        if !snapshotText.isEmpty || !snapshotToolStates.isEmpty || !snapshotPermissionStates.isEmpty {
            let snapshot = Self.bounded(AscendantTurnUpdate(
                sequence: snapshotSequence,
                kind: AscendantTurnUpdateKind.assistantTextSnapshot.rawValue,
                text: snapshotText.isEmpty ? nil : snapshotText,
                toolStates: snapshotToolStates,
                permissionStates: snapshotPermissionStates
            ), maxBytes: max(1, maxBytes - entry.bytes))
            entry.updates.insert(snapshot, at: 0)
            entry.bytes += Self.encodedSize(snapshot)
        }
    }

    private func applyRecoveredUpdate(
        timelineID: UUID,
        clientTurnID: ValidatedClientTurnID,
        update: AscendantTurnUpdate
    ) throws {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)
        if entries[key] == nil {
            evictFinishedEntriesIfNeeded(for: key)
            guard entries.count < maxEntries else { throw Error.capacityExceeded }
        }
        var entry = entries[key] ?? Entry(
            updates: [], nextSequence: 1, bytes: 0, terminal: false, finished: false, compacted: false,
            messageDigest: nil, recovered: true
        )
        apply(update, into: &entry)
        entries[key] = entry
        touch(key)
        evictIfNeeded()
    }

    public func replay(timelineID: UUID, clientTurnID: String, message: String? = nil, afterSequence: Int = 0) throws -> AscendantTurnReplay {
        let validated = try validatedClientTurnID(clientTurnID)
        return replay(timelineID: timelineID, clientTurnID: validated, message: message, afterSequence: afterSequence)
    }

    internal func replay(timelineID: UUID, clientTurnID: ValidatedClientTurnID, message: String? = nil, afterSequence: Int = 0) -> AscendantTurnReplay {
        guard let entry = entries[Key(timelineID: timelineID, clientTurnID: clientTurnID.rawValue)] else {
            return AscendantTurnReplay(updates: [], compacted: false, terminal: false)
        }
        if let message, let digest = entry.messageDigest, digest != Self.messageDigest(message) {
            return AscendantTurnReplay(updates: [], compacted: false, terminal: true, conflict: true)
        }
        let available = entry.updates.filter { $0.sequence > afterSequence }
        var updates: [AscendantTurnUpdate] = []
        for update in available {
            let candidate = updates + [update]
            let replay = AscendantTurnReplay(
                updates: candidate,
                compacted: entry.compacted && afterSequence < (entry.updates.first?.sequence ?? 0),
                terminal: entry.terminal
            )
            guard (try? GnosticWirePayload.encode(replay, context: "ascendant.turn.replay result")) != nil else { break }
            updates.append(update)
        }
        let nextSequence = updates.last?.sequence != available.last?.sequence ? updates.last?.sequence : nil
        return AscendantTurnReplay(
            updates: updates,
            compacted: entry.compacted && afterSequence < (entry.updates.first?.sequence ?? 0),
            terminal: entry.terminal,
            nextSequence: nextSequence
        )
    }

    private func touch(_ key: Key) {
        entryOrder.removeAll { $0 == key }
        entryOrder.append(key)
    }

    private func evictFinishedEntriesIfNeeded(for incoming: Key) {
        while entries.count >= maxEntries {
            guard let oldest = entryOrder.first(where: { key in
                key != incoming && entries[key]?.finished == true
            }) else { return }
            entryOrder.removeAll { $0 == oldest }
            entries.removeValue(forKey: oldest)
        }
    }

    private func evictIfNeeded() {
        while entryOrder.count > maxEntries || retainedBytes > maxBytes {
            guard let oldest = entryOrder.first(where: { entries[$0]?.finished == true }) else { return }
            entryOrder.removeAll { $0 == oldest }
            entries.removeValue(forKey: oldest)
        }
    }

    private var retainedBytes: Int {
        entries.values.reduce(0) { $0 + $1.bytes }
    }

    private static func encodedSize(_ update: AscendantTurnUpdate) -> Int {
        (try? JSONEncoder().encode(update).count) ?? 0
    }

    /// The projected on-disk size of `records`, including framing overhead, or
    /// `nil` when a record cannot be encoded.
    private static func encodedSize(_ records: [TurnEventRecord]) -> Int? {
        var total = 0
        for record in records {
            guard let size = try? JSONEncoder().encode(record).count else { return nil }
            total += size + 32
        }
        return total
    }

    /// Splits assistant text on scalar boundaries into pieces that each survive
    /// ``bounded(_:maxBytes:)`` whole. JSON escaping counts: 800 quotes encode to
    /// 1,600 bytes, so a piece can hold fewer than `maxAssistantTextBytes` bytes.
    private static func assistantTextPieces(_ text: String, kind: String, maxBytes: Int) -> [String] {
        guard text.utf8.count > maxAssistantTextBytes || !fits(text, kind: kind, maxBytes: maxBytes) else {
            return [text]
        }
        var pieces: [String] = []
        var rest = text.unicodeScalars[...]
        while !rest.isEmpty {
            var end = rest.startIndex
            var bytes = 0
            while end != rest.endIndex {
                let width = UTF8.width(rest[end])
                guard bytes + width <= maxAssistantTextBytes else { break }
                bytes += width
                end = rest.index(after: end)
            }
            var window = rest[..<end]
            while window.count > 1, !fits(String(window), kind: kind, maxBytes: maxBytes) {
                window = window.prefix(window.count / 2)
            }
            pieces.append(String(window))
            rest = rest[window.endIndex...]
        }
        return pieces
    }

    private static func fits(_ text: String, kind: String, maxBytes: Int) -> Bool {
        // The sequence is set high so a piece still fits once a real one is assigned.
        encodedSize(AscendantTurnUpdate(sequence: Int(Int32.max), kind: kind, text: text)) <= maxBytes
    }

    /// `text` within `maximumBytes`. A retention snapshot that loses text says so.
    private static func clipped(_ text: String, maximumBytes: Int, kind: String) -> String {
        guard text.utf8.count > maximumBytes,
              kind == AscendantTurnUpdateKind.assistantTextSnapshot.rawValue else {
            return GnosticWirePayload.prefix(text, maximumBytes: maximumBytes)
        }
        return markedPrefix(text, maximumBytes: maximumBytes)
    }

    /// A prefix ending in ``truncationMarker``, within `maximumBytes` in total.
    private static func markedPrefix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let room = maximumBytes - truncationMarker.utf8.count
        guard room > 0 else { return GnosticWirePayload.prefix(truncationMarker, maximumBytes: maximumBytes) }
        return GnosticWirePayload.prefix(text, maximumBytes: room) + truncationMarker
    }

    private static func bounded(_ update: AscendantTurnUpdate, maxBytes: Int) -> AscendantTurnUpdate {
        var text = update.text.map { clipped($0, maximumBytes: maxAssistantTextBytes, kind: update.kind) }
        let toolState = update.toolState.map(bounded)
        var toolStates = update.toolStates.map(bounded)
        let permissionState = update.permissionState.map(bounded)
        var permissionStates = update.permissionStates.map(bounded)
        let kind = GnosticWirePayload.boundedIdentifier(update.kind)
        var candidate = update
        candidate = AscendantTurnUpdate(
            sequence: update.sequence, kind: kind, text: text, toolState: toolState,
            toolStates: toolStates, permissionState: permissionState,
            permissionStates: permissionStates, terminal: update.terminal,
            reasonCode: update.reasonCode, statusCode: update.statusCode,
            retryable: update.retryable
        )
        while encodedSize(candidate) > maxBytes, let current = text, !current.isEmpty {
            // A single byte halves to nothing, so this loop always ends.
            text = clipped(current, maximumBytes: current.utf8.count / 2, kind: update.kind)
            candidate = AscendantTurnUpdate(
                sequence: update.sequence, kind: kind,
                text: text,
                toolState: toolState,
                toolStates: toolStates,
                permissionState: permissionState,
                permissionStates: permissionStates,
                terminal: update.terminal,
                reasonCode: update.reasonCode,
                statusCode: update.statusCode,
                retryable: update.retryable
            )
        }
        while encodedSize(candidate) > maxBytes, !toolStates.isEmpty {
            toolStates.removeFirst()
            candidate = AscendantTurnUpdate(
                sequence: update.sequence,
                kind: kind,
                text: text,
                toolState: toolState,
                toolStates: toolStates,
                permissionState: permissionState,
                permissionStates: permissionStates,
                terminal: update.terminal,
                reasonCode: update.reasonCode,
                statusCode: update.statusCode,
                retryable: update.retryable
            )
        }
        while encodedSize(candidate) > maxBytes, !permissionStates.isEmpty {
            permissionStates.removeFirst()
            candidate = AscendantTurnUpdate(
                sequence: update.sequence,
                kind: kind,
                text: text,
                toolState: toolState,
                toolStates: toolStates,
                permissionState: update.permissionState,
                permissionStates: permissionStates,
                terminal: update.terminal,
                reasonCode: update.reasonCode,
                statusCode: update.statusCode,
                retryable: update.retryable
            )
        }
        return candidate
    }

    private static func bounded(_ state: AscendantToolState) -> AscendantToolState {
        AscendantToolState(
            toolCallID: GnosticWirePayload.boundedIdentifier(state.toolCallID),
            title: state.title.map { GnosticWirePayload.boundedLabel($0) },
            status: GnosticWirePayload.boundedIdentifier(state.status),
            content: state.content.map { markedPrefix($0, maximumBytes: 256) }
        )
    }

    private static func bounded(_ state: AscendantPermissionState) -> AscendantPermissionState {
        AscendantPermissionState(
            correlationID: GnosticWirePayload.boundedIdentifier(state.correlationID),
            toolCallID: GnosticWirePayload.boundedIdentifier(state.toolCallID),
            title: GnosticWirePayload.boundedLabel(state.title),
            status: GnosticWirePayload.boundedIdentifier(state.status)
        )
    }

    private static func upsert(_ state: AscendantToolState, into states: inout [AscendantToolState]) {
        if let index = states.firstIndex(where: { $0.toolCallID == state.toolCallID }) {
            states[index] = state
        } else {
            states.append(state)
        }
    }

    private static func upsert(
        _ state: AscendantPermissionState,
        into states: inout [AscendantPermissionState]
    ) {
        if let index = states.firstIndex(where: { $0.correlationID == state.correlationID }) {
            states[index] = state
        } else {
            states.append(state)
        }
    }

    /// The admission digest of an identified Turn's message: the SHA-256 of the
    /// RFC 8785 canonical form of its prompt content and the ACP version tag
    /// (ADR 0021 Turn semantics). It is process-stable and never stores the
    /// message itself.
    static func messageDigest(_ message: String) -> String {
        // A text prompt always canonicalizes, so the fallback is unreachable.
        // It stays deterministic rather than trapping on an impossible failure.
        (try? TurnAdmissionDigest.hex(
            prompt: timelineAdmissionPrompt(message),
            acpVersionTag: ACPv2Protocol.versionTag
        )) ?? SHA256.hexDigest(message)
    }

    private static func timelineAdmissionPrompt(_ message: String) -> [ACPContentBlock] {
        [.text(ACPTextContent(text: message))]
    }
}
