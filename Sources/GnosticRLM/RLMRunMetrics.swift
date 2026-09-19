// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Deterministic counters and timings for one RLM run.
public struct RLMRunMetrics: Sendable, Equatable {
    public let snapshotID: String
    public internal(set) var rootIterations = 0
    public internal(set) var rootCellRejections = 0
    public internal(set) var leafModelCalls = 0
    public internal(set) var leafPrompts = 0
    public internal(set) var corpusFiles = 0
    public internal(set) var corpusChunks = 0
    public internal(set) var corpusBytes = 0
    public internal(set) var skippedFiles = 0
    public internal(set) var corpusSearchCalls = 0
    public internal(set) var corpusReadCalls = 0
    public internal(set) var contextReadBytes = 0
    public internal(set) var estimatedModelTokens = 0
    public internal(set) var cellOutputBytes = 0
    public internal(set) var evidenceReferences = 0
    public internal(set) var wallDuration: Duration = .zero

    public init(snapshotID: String) {
        self.snapshotID = snapshotID
    }

    /// A zeroed metric set for a run that failed before a snapshot was committed.
    public static func unavailable() -> RLMRunMetrics {
        RLMRunMetrics(snapshotID: "unavailable")
    }
}
