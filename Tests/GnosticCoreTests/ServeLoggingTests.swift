// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging
import Testing

@testable import GnosticCore

/// An in-memory handler that retains the records it observes.
final class RecordingLogHandler: LogHandler, @unchecked Sendable {
    struct Record {
        let level: Logger.Level
        let message: String
        let metadata: Logger.Metadata
    }

    private var lock = NSLock()
    private var storage: [Record] = []
    var records: [Record] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    var metadataProvider: Logger.MetadataProvider? = nil

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(Record(level: event.level, message: event.message.description, metadata: event.metadata ?? [:]))
    }
}

@Suite("Serve trace logging")
struct ServeLoggingTests {
    /// A logger routed to the in-memory handler.
    private func makeCapturingLogger() -> (Logger, RecordingLogHandler) {
        let handler = RecordingLogHandler()
        let logger = Logger(label: "test.serve") { _ in handler }
        return (logger, handler)
    }

    @Test("advertisement records the object count and timeline as structured fields")
    func advertisedFields() throws {
        let (logger, handler) = makeCapturingLogger()
        let timeline = UUID()
        ServeTrace.advertised(logger: logger, objects: 3, timelineID: timeline)
        let record = try #require(handler.records.first)
        #expect(record.level == .info)
        #expect(record.message == "advertised objects")
        #expect(record.metadata["objectCount"] == .stringConvertible(3))
        #expect(record.metadata["timeline"] == .string(timeline.uuidString.lowercased()))
    }

    @Test("subsystem label is stable and service-scoped")
    func subsystemLabel() {
        #expect(ServeLogging.subsystem == "me.atkn.gnostic.serve")
        #expect(ServeLogging.makeLogger().label == "me.atkn.gnostic.serve")
    }
}
