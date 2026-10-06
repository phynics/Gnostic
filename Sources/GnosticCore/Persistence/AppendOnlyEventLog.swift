// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A failure while reading or writing a durable event log.
public enum EventLogError: Swift.Error, Sendable, Equatable, LocalizedError {
    /// A record is not framed as `checksum timestamp payload`.
    case malformedRecord
    /// A record's checksum does not match its bytes.
    case checksumMismatch
    /// The log file could not be created.
    case cannotOpenFile(path: String)

    public var errorDescription: String? {
        switch self {
        case .malformedRecord:
            "the event log record is not framed correctly"
        case .checksumMismatch:
            "the event log record failed its checksum"
        case .cannotOpenFile(let path):
            "the event log file could not be created at \(path)"
        }
    }
}

/// One decoded record in an ``AppendOnlyEventLog``.
public struct EventLogEnvelope<Payload: Codable & Sendable & Equatable>: Sendable, Equatable {
    /// The wall-clock time the record was appended.
    public let recordedAt: Date
    /// The caller-owned payload.
    public let payload: Payload

    public init(recordedAt: Date, payload: Payload) {
        self.recordedAt = recordedAt
        self.payload = payload
    }
}

/// Why a read-only scan stopped before the end of an ``AppendOnlyEventLog``.
public enum EventLogTailKind: String, Codable, Sendable, Equatable {
    /// The final record is incomplete or fails verification, as after a crash.
    case torn
    /// A record before the end of the file is malformed or unreadable.
    case corrupt
}

/// The unreadable suffix a read-only scan found.
public struct EventLogTail: Sendable, Equatable {
    /// Whether the suffix looks like an interrupted final write or real damage.
    public let kind: EventLogTailKind
    /// A human-readable explanation of why decoding stopped.
    public let reason: String
    /// The number of bytes that decoded successfully.
    public let validByteCount: Int
    /// The total size of the scanned file.
    public let totalByteCount: Int

    public init(
        kind: EventLogTailKind,
        reason: String,
        validByteCount: Int,
        totalByteCount: Int
    ) {
        self.kind = kind
        self.reason = reason
        self.validByteCount = validByteCount
        self.totalByteCount = totalByteCount
    }
}

/// The result of a read-only ``AppendOnlyEventLog/scan()``.
public struct EventLogScan<Payload: Codable & Sendable & Equatable>: Sendable, Equatable {
    /// Every record that decoded successfully, in append order.
    public let records: [EventLogEnvelope<Payload>]
    /// The unreadable suffix, or `nil` when the whole file decoded.
    public let tail: EventLogTail?

    public init(records: [EventLogEnvelope<Payload>], tail: EventLogTail?) {
        self.records = records
        self.tail = tail
    }
}

/// A crash-safe, append-only record log.
///
/// The log stores one self-framed record per line:
///
/// ```
/// <fnv1a64-hex> <unix-milliseconds> <utf8-json>\n
/// ```
///
/// `append` writes the frame, flushes it, and returns. It opens, writes, and
/// closes the file per call, so the value is `Sendable` and safe to hold from
/// any actor. `recover` verifies each record. Because the format is
/// append-only and self-framing, a crash can only tear the final record, so
/// recovery treats the first unreadable record as a torn tail, returns every
/// valid record before it, and truncates the file to the valid prefix.
///
/// The log owns no Gnostic types. Any layer that can define a `Codable`
/// payload can persist through this shared interface.
public struct AppendOnlyEventLog<Payload: Codable & Sendable & Equatable>: Sendable {
    /// The file records are appended to.
    public let fileURL: URL
    /// Whether each append flushes to disk before returning.
    public let synchronizeEachAppend: Bool

    public init(fileURL: URL, synchronizeEachAppend: Bool = true) {
        self.fileURL = fileURL
        self.synchronizeEachAppend = synchronizeEachAppend
    }

    /// Appends one record and returns its decoded form.
    ///
    /// The record is durable when this method returns.
    @discardableResult
    public func append(_ payload: Payload) throws -> EventLogEnvelope<Payload> {
        try createFileIfNeeded()
        let recordedAt = Date()
        let frame = try encodedFrame(payload, at: recordedAt)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: frame)
        if synchronizeEachAppend {
            try handle.synchronize()
        }
        return EventLogEnvelope(recordedAt: recordedAt, payload: payload)
    }

    /// The current size of the log file in bytes, or zero when it does not exist.
    public func byteCount() throws -> UInt64 {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Atomically replaces the entire log with `payloads`.
    ///
    /// Use this only to write a bounded checkpoint that supersedes the current
    /// contents; normal writes must use ``append(_:)``. The replacement is
    /// written to a temporary sibling file, flushed, and renamed over the log,
    /// so a crash leaves either the previous log or the complete replacement,
    /// never a partial file. The replacement keeps `0o600` permissions, and the
    /// next ``append(_:)`` resumes after the replacement.
    public func replaceAll(with payloads: [Payload]) throws {
        try createFileIfNeeded()
        var data = Data()
        for payload in payloads {
            data.append(try encodedFrame(payload, at: Date()))
        }

        let temporaryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw EventLogError.cannotOpenFile(path: temporaryURL.path)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            if synchronizeEachAppend {
                try handle.synchronize()
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
    }

    /// Reads every valid record without modifying the file.
    ///
    /// The scan verifies each record checksum and reports the first unreadable
    /// record as a ``EventLogTail``. Unlike ``recover()``, it never truncates or
    /// creates the file, so a read-only viewer can inspect the log while the
    /// writer keeps ownership of recovery.
    public func scan() throws -> EventLogScan<Payload> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EventLogScan(records: [], tail: nil)
        }
        let data = try Data(contentsOf: fileURL)
        return walk(data)
    }

    /// Reads every valid record, in append order.
    ///
    /// A torn or corrupt tail is truncated so it cannot accumulate. Recovery
    /// uses the same decode walk as ``scan()`` so the two cannot diverge.
    public func recover() throws -> [EventLogEnvelope<Payload>] {
        let scan = try scan()
        if let tail = scan.tail {
            try truncate(to: tail.validByteCount)
        }
        return scan.records
    }

    private func walk(_ data: Data) -> EventLogScan<Payload> {
        var records: [EventLogEnvelope<Payload>] = []
        var validByteCount = 0
        var cursor = data.startIndex
        var tail: EventLogTail?
        while cursor < data.endIndex {
            guard let newline = data[cursor...].firstIndex(of: 0x0A) else {
                tail = EventLogTail(
                    kind: .torn,
                    reason: "the final record has no terminating newline",
                    validByteCount: validByteCount,
                    totalByteCount: data.count
                )
                break
            }
            let line = data[cursor..<newline]
            do {
                records.append(try decode(line))
                validByteCount = data.distance(from: data.startIndex, to: data.index(after: newline))
                cursor = data.index(after: newline)
            } catch {
                let isFinalLine = data.index(after: newline) >= data.endIndex
                tail = EventLogTail(
                    kind: isFinalLine ? .torn : .corrupt,
                    reason: Self.reason(for: error),
                    validByteCount: validByteCount,
                    totalByteCount: data.count
                )
                break
            }
        }
        return EventLogScan(records: records, tail: tail)
    }

    private static func reason(for error: any Swift.Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    private func decode(_ line: Data) throws -> EventLogEnvelope<Payload> {
        guard let firstSpace = line.firstIndex(of: 0x20) else { throw EventLogError.malformedRecord }
        guard let checksumText = String(bytes: line[line.startIndex..<firstSpace], encoding: .utf8),
              let expected = UInt64(checksumText, radix: 16) else {
            throw EventLogError.malformedRecord
        }
        let bodyStart = line.index(after: firstSpace)
        guard bodyStart < line.endIndex else { throw EventLogError.malformedRecord }
        let body = line[bodyStart...]
        guard Self.checksum(body) == expected else { throw EventLogError.checksumMismatch }
        guard let secondSpace = body.firstIndex(of: 0x20) else { throw EventLogError.malformedRecord }
        guard let millisecondsText = String(bytes: body[body.startIndex..<secondSpace], encoding: .utf8),
              let milliseconds = Int64(millisecondsText) else {
            throw EventLogError.malformedRecord
        }
        let jsonStart = body.index(after: secondSpace)
        guard jsonStart <= body.endIndex else { throw EventLogError.malformedRecord }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(body[jsonStart...]))
        return EventLogEnvelope(
            recordedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            payload: payload
        )
    }

    private func encodedFrame(_ payload: Payload, at recordedAt: Date) throws -> Data {
        let milliseconds = Int64((recordedAt.timeIntervalSince1970 * 1_000).rounded())
        let json = try JSONEncoder().encode(payload)
        var body = Data(String(milliseconds).utf8)
        body.append(0x20)
        body.append(json)

        var frame = Data(Self.hex(Self.checksum(body)).utf8)
        frame.append(0x20)
        frame.append(body)
        frame.append(0x0A)
        return frame
    }

    private func createFileIfNeeded() throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        guard fileManager.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw EventLogError.cannotOpenFile(path: fileURL.path)
        }
    }

    private func truncate(to offset: Int) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.synchronize()
    }

    /// The FNV-1a 64-bit checksum used for torn-write detection.
    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}
