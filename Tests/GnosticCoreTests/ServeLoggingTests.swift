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

    @Test("startup records host, port, namespace, and timeline as structured fields")
    func startupFields() {
        let (logger, handler) = makeCapturingLogger()
        let timeline = UUID()
        ServeTrace.startup(
            logger: logger, host: "127.0.0.1", port: 1883, namespace: "gnostic", timelineID: timeline
        )
        let record = try! #require(handler.records.first)
        #expect(record.level == .info)
        #expect(record.message == "serve startup")
        #expect(record.metadata["host"] == .string("127.0.0.1"))
        #expect(record.metadata["port"] == .stringConvertible(1883))
        #expect(record.metadata["namespace"] == .string("gnostic"))
        #expect(record.metadata["timeline"] == .string(timeline.uuidString.lowercased()))
    }

    @Test("operation success carries operation and identifiers")
    func operationSuccessFields() {
        let (logger, handler) = makeCapturingLogger()
        let timeline = UUID()
        let workspace = UUID()
        ServeTrace.operationSucceeded(
            logger: logger, operation: "me.atkn.gnostic.workspace.attach",
            timelineID: timeline, workspaceID: workspace
        )
        let record = try! #require(handler.records.first)
        #expect(record.level == .info)
        #expect(record.metadata["operation"] == .string("me.atkn.gnostic.workspace.attach"))
        #expect(record.metadata["result"] == .string("success"))
        #expect(record.metadata["timeline"] == .string(timeline.uuidString.lowercased()))
        #expect(record.metadata["workspace"] == .string(workspace.uuidString.lowercased()))
    }

    @Test("denials and failures log at warning/error with reason")
    func denialAndFailureLevels() {
        let (logger, handler) = makeCapturingLogger()
        let timeline = UUID()
        ServeTrace.operationDenied(
            logger: logger, operation: "me.atkn.gnostic.workspace.attach",
            timelineID: timeline, workspaceID: nil, reason: "approvalRequired"
        )
        ServeTrace.operationFailed(
            logger: logger, operation: "me.atkn.gnostic.agent.chat",
            timelineID: timeline, workspaceID: nil, error: "llmServiceNotConfigured"
        )
        try! #require(handler.records.count == 2)
        #expect(handler.records[0].level == .warning)
        #expect(handler.records[0].metadata["reason"] == .string("approvalRequired"))
        #expect(handler.records[1].level == .error)
        #expect(handler.records[1].metadata["error"] == .string("llmServiceNotConfigured"))
    }

    @Test("subsystem label is stable and service-scoped")
    func subsystemLabel() {
        #expect(ServeLogging.subsystem == "me.atkn.gnostic.serve")
        #expect(ServeLogging.makeLogger().label == "me.atkn.gnostic.serve")
    }
}