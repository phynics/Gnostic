// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// A stable, read-only summary of one durable Turn event log.
///
/// The report is the machine-readable contract for `gnostic turn-log --format
/// json`. It never contains prompt text: ``TurnEventRecord`` already stores
/// only the prompt digest and the bounded update payload.
struct TurnLogReport: Codable, Equatable {
    /// The resolved log path.
    let path: String
    /// Whether the log file exists on disk.
    let exists: Bool
    /// The number of records that decoded successfully.
    let recordCount: Int
    /// The number of distinct turns the records describe.
    let turnCount: Int
    /// Whether every decoded record verified its checksum.
    let checksumsValid: Bool
    /// The unreadable suffix, or `nil` when the whole file decoded.
    let tail: TurnLogTailReport?
    /// The journaled turns, in first-seen order.
    let turns: [TurnSummary]

    init(scan: EventLogScan<TurnEventRecord>, path: String, exists: Bool) {
        self.path = path
        self.exists = exists
        self.recordCount = scan.records.count
        self.checksumsValid = scan.tail == nil
        self.tail = scan.tail.map(TurnLogTailReport.init)
        self.turns = Self.group(scan.records)
        self.turnCount = self.turns.count
    }

    private struct TurnKey: Hashable {
        let timelineID: UUID
        let clientTurnID: String
    }

    private struct Accumulator {
        var events = 0
        var updates = 0
        var finished = false
        var compacted = false
        var startedAt: Date?
        var lastRecordedAt: Date?
        var messageDigest: UInt64?
        var lastSequence: Int?
        var terminal: Bool?
    }

    private static func group(_ envelopes: [EventLogEnvelope<TurnEventRecord>]) -> [TurnSummary] {
        var order: [TurnKey] = []
        var accumulators: [TurnKey: Accumulator] = [:]
        for envelope in envelopes {
            let record = envelope.payload
            let key = TurnKey(timelineID: record.timelineID, clientTurnID: record.clientTurnID)
            var accumulator = accumulators[key] ?? Accumulator()
            if accumulators[key] == nil {
                order.append(key)
            }
            accumulator.events += 1
            accumulator.lastRecordedAt = envelope.recordedAt
            switch record.event {
            case .started(let messageDigest):
                accumulator.startedAt = envelope.recordedAt
                accumulator.messageDigest = messageDigest
            case .update(let update):
                accumulator.updates += 1
                accumulator.lastSequence = update.sequence
                accumulator.terminal = update.terminal
            case .finished:
                accumulator.finished = true
            case .checkpoint(let checkpoint):
                accumulator.compacted = true
                if let digest = checkpoint.messageDigest {
                    accumulator.messageDigest = digest
                }
                accumulator.updates += checkpoint.updates.count
                if checkpoint.finished {
                    accumulator.finished = true
                }
                accumulator.terminal = checkpoint.terminal
                if checkpoint.nextSequence > 0 {
                    accumulator.lastSequence = checkpoint.nextSequence - 1
                }
            }
            accumulators[key] = accumulator
        }
        return order.map { key in
            let accumulator = accumulators[key] ?? Accumulator()
            return TurnSummary(
                timelineID: key.timelineID.uuidString.lowercased(),
                clientTurnID: key.clientTurnID,
                events: accumulator.events,
                updates: accumulator.updates,
                finished: accumulator.finished,
                compacted: accumulator.compacted,
                startedAt: accumulator.startedAt.map(timestamp),
                lastRecordedAt: accumulator.lastRecordedAt.map(timestamp),
                messageDigest: accumulator.messageDigest,
                lastSequence: accumulator.lastSequence,
                terminal: accumulator.terminal
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// The unreadable suffix of a scanned Turn event log.
struct TurnLogTailReport: Codable, Equatable {
    /// `torn` for an interrupted final write, `corrupt` for damage before the end.
    let kind: String
    /// A human-readable explanation of why decoding stopped.
    let reason: String
    /// The number of bytes that decoded successfully.
    let validBytes: Int
    /// The total size of the scanned file.
    let totalBytes: Int

    init(_ tail: EventLogTail) {
        self.kind = tail.kind.rawValue
        self.reason = tail.reason
        self.validBytes = tail.validByteCount
        self.totalBytes = tail.totalByteCount
    }
}

/// One journaled Turn in a ``TurnLogReport``.
struct TurnSummary: Codable, Equatable {
    /// The Timeline the Turn belongs to.
    let timelineID: String
    /// The client turn identifier.
    let clientTurnID: String
    /// The number of durable records for the Turn.
    let events: Int
    /// The number of `.update` records for the Turn.
    let updates: Int
    /// Whether the Turn's retention slot was released.
    let finished: Bool
    /// Whether a compaction checkpoint represents the Turn.
    let compacted: Bool
    /// When the Turn's `.started` record was written.
    let startedAt: String?
    /// When the Turn's last record was written.
    let lastRecordedAt: String?
    /// The prompt digest, when a `.started` record carried one.
    let messageDigest: UInt64?
    /// The highest update sequence observed.
    let lastSequence: Int?
    /// Whether the last update marked the Turn terminal.
    let terminal: Bool?
}

extension TurnLogReport {
    /// Renders the operator-facing view.
    func humanDescription() -> String {
        var lines = ["Turn event log \(path)"]
        if !exists {
            lines.append("  file does not exist; no turns journaled")
        } else {
            let checksumText = checksumsValid ? "ok" : "failed"
            lines.append("  \(recordCount) record(s), \(turnCount) turn(s), checksums \(checksumText)")
        }
        if let tail {
            lines.append(
                "  \(tail.kind) tail: \(tail.reason) "
                    + "(valid \(tail.validBytes) of \(tail.totalBytes) bytes; file unchanged)"
            )
        } else {
            lines.append("  no torn or corrupt tail")
        }
        for turn in turns {
            lines.append(turn.humanDescription())
        }
        return lines.joined(separator: "\n")
    }
}

extension TurnSummary {
    /// Renders one operator-facing line.
    func humanDescription() -> String {
        var detail = "events=\(events) updates=\(updates)"
        if finished {
            detail += " finished"
        }
        if compacted {
            detail += " compacted"
        }
        if let lastSequence {
            detail += " sequence=\(lastSequence)"
        }
        if terminal == true {
            detail += " terminal"
        }
        if let messageDigest {
            detail += " digest=\(String(messageDigest, radix: 16))"
        }
        return "  \(timelineID) turn \(clientTurnID): \(detail)"
    }
}
