// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One recorded event in a Run's trace.
///
/// The event is a flat, kit-owned value, so the tape stays stable JSON and never
/// names a backend type. `label` and `detail` carry the kind-specific payload:
///
/// | `kind` | `label` | `detail` |
/// | --- | --- | --- |
/// | `modelRequest` | the model tier | the prompt |
/// | `modelResponse` | empty | the response text |
/// | `toolCall` | the tool name | the arguments |
/// | `toolResult` | the tool name | the result |
/// | `outcome` | the outcome | the failure category, or empty |
///
/// Every event carries the Turn id it belongs to and its position in the tape.
public struct ExperimentTraceEvent: Codable, Sendable, Equatable {
    /// The kind of event the tape records.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A model request the harness sent.
        case modelRequest
        /// A model response the harness received.
        case modelResponse
        /// A tool call the harness made.
        case toolCall
        /// A tool result the harness received.
        case toolResult
        /// The run's terminal outcome.
        case outcome
    }

    /// The 1-based position in the tape.
    public let sequence: Int
    /// The id of the Turn this event belongs to.
    public let turnID: String
    /// The event kind.
    public let kind: Kind
    /// The kind-specific label.
    public let label: String
    /// The kind-specific payload.
    public let detail: String
    /// Prompt tokens the provider reported, on a model response.
    public let promptTokens: Int?
    /// Completion tokens the provider reported, on a model response.
    public let completionTokens: Int?
    /// Whether the event records a failure.
    public let failed: Bool

    /// Creates one trace event.
    public init(
        sequence: Int,
        turnID: String,
        kind: Kind,
        label: String,
        detail: String,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        failed: Bool = false
    ) {
        self.sequence = sequence
        self.turnID = turnID
        self.kind = kind
        self.label = label
        self.detail = detail
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.failed = failed
    }
}

/// A deterministic, content-addressable tape of one Run.
///
/// The tape is the P4 record: model requests and responses, tool calls and
/// results, and the run outcome, in order and correlated by Turn. It holds
/// payloads because a caller built a recorder explicitly; nothing records by
/// default.
public struct ExperimentTrace: Codable, Sendable, Equatable {
    /// The tape schema version.
    public static let currentSchemaVersion = 1

    /// The tape schema version this value was written with.
    public let schemaVersion: Int
    /// The run identity the tape belongs to.
    public let runID: String
    /// The Regime label, when the run named one.
    public let regime: String?
    /// The start time, ISO-8601.
    public let startedAtUTC: String
    /// The ordered events.
    public let events: [ExperimentTraceEvent]

    /// Creates one tape.
    public init(
        schemaVersion: Int = ExperimentTrace.currentSchemaVersion,
        runID: String,
        regime: String? = nil,
        startedAtUTC: String,
        events: [ExperimentTraceEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.regime = regime
        self.startedAtUTC = startedAtUTC
        self.events = events
    }

    /// The model-response events, in order.
    public var modelResponses: [ExperimentTraceEvent] {
        events.filter { $0.kind == .modelResponse }
    }

    /// The terminal outcome event, when the run recorded one.
    public var outcome: ExperimentTraceEvent? {
        events.last { $0.kind == .outcome }
    }

    /// The canonical JSON encoding: sorted keys, no escaped slashes, no
    /// trailing newline. The digest is taken over these bytes.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The lowercase hexadecimal SHA-256 of the canonical JSON.
    public func digest() throws -> String {
        ExperimentDigest.sha256Hex([UInt8](try canonicalJSON()))
    }
}

/// Reads and writes a trace as JSON.
public enum ExperimentTraceFile {
    /// Reads a trace, or nil when the path does not exist.
    public static func read(_ url: URL) throws -> ExperimentTrace? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExperimentTrace.self, from: Data(contentsOf: url))
    }

    /// Writes a trace, creating parent directories, with a trailing newline.
    public static func write(_ trace: ExperimentTrace, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(trace)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Accumulates a Run's tape while it executes.
///
/// The recorder is the opt-in switch: a Run records only when its owner builds
/// one and routes events to it. It assigns each event its sequence number and
/// the current Turn id, so a driver can begin a Turn before its model and tool
/// events.
public actor ExperimentTraceRecorder {
    /// The run identity the tape belongs to.
    public let runID: String
    private var events: [ExperimentTraceEvent] = []
    private var turnCount = 1
    private var currentTurnID = "turn-1"

    /// Creates a recorder for one run.
    public init(runID: String) {
        self.runID = runID
    }

    /// The Turn id new events attach to.
    public var turnID: String { currentTurnID }

    /// Starts a Turn and returns its id.
    ///
    /// - Parameter id: An explicit Turn id, or nil to allocate `turn-<n>`.
    /// - Returns: The id new events attach to.
    @discardableResult
    public func beginTurn(_ id: String? = nil) -> String {
        if let id {
            currentTurnID = id
        } else {
            turnCount += 1
            currentTurnID = "turn-\(turnCount)"
        }
        return currentTurnID
    }

    /// Records a model request in the current Turn.
    public func recordModelRequest(prompt: String, tier: ExperimentModelTier) {
        append(kind: .modelRequest, label: tier.rawValue, detail: prompt)
    }

    /// Records a model response in the current Turn.
    public func recordModelResponse(
        text: String,
        promptTokens: Int?,
        completionTokens: Int?,
        failed: Bool = false
    ) {
        append(
            kind: .modelResponse,
            label: "",
            detail: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            failed: failed
        )
    }

    /// Records a tool call in the current Turn.
    public func recordToolCall(name: String, arguments: String) {
        append(kind: .toolCall, label: name, detail: arguments)
    }

    /// Records a tool result in the current Turn.
    public func recordToolResult(name: String, result: String, failed: Bool = false) {
        append(kind: .toolResult, label: name, detail: result, failed: failed)
    }

    /// Records the run outcome in the current Turn.
    public func recordOutcome(_ outcome: String, failureCategory: String? = nil) {
        append(kind: .outcome, label: outcome, detail: failureCategory ?? "")
    }

    /// The events recorded so far, in order.
    public func snapshot() -> [ExperimentTraceEvent] { events }

    /// Builds the tape from the recorded events.
    public func trace(regime: String? = nil, startedAtUTC: String = "1970-01-01T00:00:00Z") -> ExperimentTrace {
        ExperimentTrace(runID: runID, regime: regime, startedAtUTC: startedAtUTC, events: events)
    }

    private func append(
        kind: ExperimentTraceEvent.Kind,
        label: String,
        detail: String,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        failed: Bool = false
    ) {
        events.append(ExperimentTraceEvent(
            sequence: events.count + 1,
            turnID: currentTurnID,
            kind: kind,
            label: label,
            detail: detail,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            failed: failed
        ))
    }
}
