// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// A durable, append-only journal for one Run's trace tape (GNO-PLAT-P8, #461).
///
/// The journal reuses the kernel's ``AppendOnlyEventLog`` so a Run that crashes
/// mid-tape recovers the events it recorded before the crash. It is a plain
/// `Sendable` value, and ``ExperimentTraceRecorder`` owns the only writer.
public struct ExperimentTraceJournal: Sendable {
    private let log: AppendOnlyEventLog<ExperimentTraceEvent>

    /// Creates a journal at `fileURL`.
    public init(fileURL: URL) {
        log = AppendOnlyEventLog(fileURL: fileURL)
    }

    /// The valid events already on disk, in order.
    public func recover() throws -> [ExperimentTraceEvent] {
        try log.recover().map(\.payload)
    }

    /// Appends one event and returns its envelope.
    @discardableResult
    public func append(_ event: ExperimentTraceEvent) throws -> EventLogEnvelope<ExperimentTraceEvent> {
        try log.append(event)
    }
}
