// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The one recover-replay-install sequence for a journaled store.
///
/// `AppendOnlyEventLog` owns the file format. Every store that journals its own
/// mutations repeats the same opening sequence:
///
/// 1. frame a log at the store's file URL,
/// 2. recover the valid prefix,
/// 3. replay each recovered record through the store's own mutation path,
/// 4. install the journal so later mutations append to it.
///
/// This type owns steps 1 through 3 and the append guard. A store keeps one
/// optional journal and supplies one replay closure:
///
/// ```swift
/// private var journal: DurableReplayJournal<StoreEvent>?
///
/// public func enableDurability(at url: URL) throws {
///     let candidate = DurableReplayJournal<StoreEvent>(fileURL: url)
///     try candidate.recover { try apply($0) }
///     journal = candidate
/// }
/// ```
///
/// The caller installs the journal only after `recover` returns, so a replayed
/// mutation never re-journals itself and a failed replay leaves the store with
/// no installed journal.
///
/// ## Recovery error policy
///
/// Recovery surfaces a replay failure. A record that cannot be applied aborts
/// `recover`, leaves the partial state local to the store, and stops the
/// caller from installing the journal. Silent partial recovery is never
/// reported as success.
///
/// Two conditions are intentionally not replay failures. A deterministic
/// retention overflow — a journal that outgrew the store's live bound — is
/// skipped by the store's replay closure, because the journal legitimately
/// exceeds the live bound. Compaction is best-effort maintenance: a failed
/// rewrite leaves a valid, if larger, journal and does not fail recovery.
///
/// The type owns no Gnostic type, so any layer that can define a `Codable`
/// payload persists through it.
public struct DurableReplayJournal<Payload: Codable & Sendable & Equatable>: Sendable {
    private let log: AppendOnlyEventLog<Payload>

    /// Creates a journal handle for `fileURL`.
    ///
    /// The handle does not open the file until ``recover(replaying:)``,
    /// ``append(_:)``, or ``replaceAll(with:)`` runs.
    public init(fileURL: URL, synchronizeEachAppend: Bool = true) {
        log = AppendOnlyEventLog(fileURL: fileURL, synchronizeEachAppend: synchronizeEachAppend)
    }

    /// The file records are appended to.
    public var fileURL: URL { log.fileURL }

    /// Recovers the valid prefix and replays each record through `replay`.
    ///
    /// The recovered records replay before the caller installs this journal, so
    /// a replayed mutation never re-journals itself. ``AppendOnlyEventLog/recover()``
    /// truncates a torn tail first, so `replay` sees only records that passed
    /// their checksum. A throwing `replay` aborts recovery and propagates to
    /// the caller.
    ///
    /// - Parameter replay: The store's own mutation path for one record.
    public func recover(replaying replay: (Payload) throws -> Void) throws {
        for envelope in try log.recover() {
            try replay(envelope.payload)
        }
    }

    /// Appends one record and returns its decoded form.
    ///
    /// The record is durable when this method returns. The append opens,
    /// writes, and closes the file per call, matching
    /// ``AppendOnlyEventLog/append(_:)``.
    @discardableResult
    public func append(_ payload: Payload) throws -> EventLogEnvelope<Payload> {
        try log.append(payload)
    }

    /// The current size of the journal file in bytes, or zero when it does not
    /// exist.
    public func byteCount() throws -> UInt64 {
        try log.byteCount()
    }

    /// Atomically replaces the entire journal with `payloads`.
    ///
    /// Use this only for bounded checkpoint compaction. The semantics match
    /// ``AppendOnlyEventLog/replaceAll(with:)``.
    public func replaceAll(with payloads: [Payload]) throws {
        try log.replaceAll(with: payloads)
    }
}
