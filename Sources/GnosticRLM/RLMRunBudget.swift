// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Host-owned limits for one RLM run.
///
/// Every limit is set by the host. A caller may only *narrow* these values with
/// an `RLMRunBudgetRequest`; no tool argument, root cell, or model response can
/// increase them.
public struct RLMRunBudget: Sendable, Equatable {
    public let maxWallDuration: Duration
    public let maxRootIterations: Int
    public let maxLeafModelCalls: Int
    public let maxEstimatedModelTokens: Int
    public let maxCorpusFiles: Int
    public let maxCorpusFileBytes: Int
    public let maxCorpusBytes: Int
    public let maxCorpusBytesRead: Int
    public let maxSchemeCellBytes: Int
    public let maxSchemeOutputBytes: Int
    public let maxEvidenceReferences: Int
    public let maxChunksPerRead: Int
    public let maxSearchLimit: Int
    /// How many recoverable cell failures may be fed back for repair in one run.
    public let maxCellRepairs: Int

    public init(
        maxWallDuration: Duration,
        maxRootIterations: Int,
        maxLeafModelCalls: Int,
        maxEstimatedModelTokens: Int,
        maxCorpusFiles: Int,
        maxCorpusFileBytes: Int,
        maxCorpusBytes: Int,
        maxCorpusBytesRead: Int,
        maxSchemeCellBytes: Int,
        maxSchemeOutputBytes: Int,
        maxEvidenceReferences: Int,
        maxChunksPerRead: Int,
        maxSearchLimit: Int,
        maxCellRepairs: Int = 3
    ) {
        self.maxWallDuration = maxWallDuration
        self.maxRootIterations = maxRootIterations
        self.maxLeafModelCalls = maxLeafModelCalls
        self.maxEstimatedModelTokens = maxEstimatedModelTokens
        self.maxCorpusFiles = maxCorpusFiles
        self.maxCorpusFileBytes = maxCorpusFileBytes
        self.maxCorpusBytes = maxCorpusBytes
        self.maxCorpusBytesRead = maxCorpusBytesRead
        self.maxSchemeCellBytes = maxSchemeCellBytes
        self.maxSchemeOutputBytes = maxSchemeOutputBytes
        self.maxEvidenceReferences = maxEvidenceReferences
        self.maxChunksPerRead = maxChunksPerRead
        self.maxSearchLimit = maxSearchLimit
        self.maxCellRepairs = maxCellRepairs
    }

    public static let standard = RLMRunBudget(
        maxWallDuration: .seconds(300),
        maxRootIterations: 8,
        maxLeafModelCalls: 32,
        maxEstimatedModelTokens: 200_000,
        maxCorpusFiles: 5_000,
        maxCorpusFileBytes: 1_048_576,
        maxCorpusBytes: 32 * 1_024 * 1_024,
        maxCorpusBytesRead: 4 * 1_024 * 1_024,
        maxSchemeCellBytes: 32 * 1_024,
        maxSchemeOutputBytes: 512 * 1_024,
        maxEvidenceReferences: 64,
        maxChunksPerRead: 32,
        maxSearchLimit: 100
    )
}

/// An optional narrowing overlay supplied by the caller.
///
/// A `nil` field keeps the host value. A non-`nil` field is clamped down to the
/// host value, so a request can never enlarge a budget.
public struct RLMRunBudgetRequest: Sendable, Equatable {
    public var maxWallDuration: Duration?
    public var maxRootIterations: Int?
    public var maxLeafModelCalls: Int?
    public var maxEstimatedModelTokens: Int?
    public var maxCorpusFiles: Int?
    public var maxCorpusFileBytes: Int?
    public var maxCorpusBytes: Int?
    public var maxCorpusBytesRead: Int?
    public var maxSchemeCellBytes: Int?
    public var maxSchemeOutputBytes: Int?
    public var maxEvidenceReferences: Int?
    public var maxChunksPerRead: Int?
    public var maxSearchLimit: Int?

    public init(
        maxWallDuration: Duration? = nil,
        maxRootIterations: Int? = nil,
        maxLeafModelCalls: Int? = nil,
        maxEstimatedModelTokens: Int? = nil,
        maxCorpusFiles: Int? = nil,
        maxCorpusFileBytes: Int? = nil,
        maxCorpusBytes: Int? = nil,
        maxCorpusBytesRead: Int? = nil,
        maxSchemeCellBytes: Int? = nil,
        maxSchemeOutputBytes: Int? = nil,
        maxEvidenceReferences: Int? = nil,
        maxChunksPerRead: Int? = nil,
        maxSearchLimit: Int? = nil
    ) {
        self.maxWallDuration = maxWallDuration
        self.maxRootIterations = maxRootIterations
        self.maxLeafModelCalls = maxLeafModelCalls
        self.maxEstimatedModelTokens = maxEstimatedModelTokens
        self.maxCorpusFiles = maxCorpusFiles
        self.maxCorpusFileBytes = maxCorpusFileBytes
        self.maxCorpusBytes = maxCorpusBytes
        self.maxCorpusBytesRead = maxCorpusBytesRead
        self.maxSchemeCellBytes = maxSchemeCellBytes
        self.maxSchemeOutputBytes = maxSchemeOutputBytes
        self.maxEvidenceReferences = maxEvidenceReferences
        self.maxChunksPerRead = maxChunksPerRead
        self.maxSearchLimit = maxSearchLimit
    }

    public static let unrestricted = RLMRunBudgetRequest()

    /// Throws when any supplied value is negative.
    public func validate() throws {
        let integers: [Int?] = [
            maxRootIterations, maxLeafModelCalls, maxEstimatedModelTokens, maxCorpusFiles,
            maxCorpusFileBytes, maxCorpusBytes, maxCorpusBytesRead, maxSchemeCellBytes,
            maxSchemeOutputBytes, maxEvidenceReferences, maxChunksPerRead, maxSearchLimit,
        ]
        if integers.contains(where: { ($0 ?? 0) < 0 }) {
            throw RLMFailure.invalidToolArguments("budget request values must not be negative")
        }
        if let duration = maxWallDuration, duration < .zero {
            throw RLMFailure.invalidToolArguments("budget request duration must not be negative")
        }
    }
}

extension RLMRunBudget {
    /// Applies a request by taking the smaller of the host and requested value.
    public func narrowed(by request: RLMRunBudgetRequest) -> RLMRunBudget {
        RLMRunBudget(
            maxWallDuration: request.maxWallDuration.map { min(maxWallDuration, $0) } ?? maxWallDuration,
            maxRootIterations: request.maxRootIterations.map { min(maxRootIterations, $0) } ?? maxRootIterations,
            maxLeafModelCalls: request.maxLeafModelCalls.map { min(maxLeafModelCalls, $0) } ?? maxLeafModelCalls,
            maxEstimatedModelTokens: request.maxEstimatedModelTokens.map { min(maxEstimatedModelTokens, $0) } ?? maxEstimatedModelTokens,
            maxCorpusFiles: request.maxCorpusFiles.map { min(maxCorpusFiles, $0) } ?? maxCorpusFiles,
            maxCorpusFileBytes: request.maxCorpusFileBytes.map { min(maxCorpusFileBytes, $0) } ?? maxCorpusFileBytes,
            maxCorpusBytes: request.maxCorpusBytes.map { min(maxCorpusBytes, $0) } ?? maxCorpusBytes,
            maxCorpusBytesRead: request.maxCorpusBytesRead.map { min(maxCorpusBytesRead, $0) } ?? maxCorpusBytesRead,
            maxSchemeCellBytes: request.maxSchemeCellBytes.map { min(maxSchemeCellBytes, $0) } ?? maxSchemeCellBytes,
            maxSchemeOutputBytes: request.maxSchemeOutputBytes.map { min(maxSchemeOutputBytes, $0) } ?? maxSchemeOutputBytes,
            maxEvidenceReferences: request.maxEvidenceReferences.map { min(maxEvidenceReferences, $0) } ?? maxEvidenceReferences,
            maxChunksPerRead: request.maxChunksPerRead.map { min(maxChunksPerRead, $0) } ?? maxChunksPerRead,
            maxSearchLimit: request.maxSearchLimit.map { min(maxSearchLimit, $0) } ?? maxSearchLimit,
            maxCellRepairs: maxCellRepairs
        )
    }

    /// Validates and applies a narrowing request against the host budget.
    public static func resolve(host: RLMRunBudget, request: RLMRunBudgetRequest) throws -> RLMRunBudget {
        try request.validate()
        return host.narrowed(by: request)
    }
}

/// The remaining non-monetary budget visible to a root model.
public struct RLMRunBudgetRemaining: Sendable, Equatable {
    public let rootIterations: Int
    public let leafModelCalls: Int
    public let estimatedModelTokens: Int
    public let contextReadBytes: Int
    public let outputBytes: Int

    public init(
        rootIterations: Int,
        leafModelCalls: Int,
        estimatedModelTokens: Int,
        contextReadBytes: Int,
        outputBytes: Int
    ) {
        self.rootIterations = rootIterations
        self.leafModelCalls = leafModelCalls
        self.estimatedModelTokens = estimatedModelTokens
        self.contextReadBytes = contextReadBytes
        self.outputBytes = outputBytes
    }
}

/// Tracks consumption against one `RLMRunBudget`.
public struct RLMRunBudgetLedger: Sendable {
    public let budget: RLMRunBudget
    public let startedAt: Duration
    public private(set) var rootIterations = 0
    public private(set) var leafModelCalls = 0
    public private(set) var estimatedModelTokens = 0
    public private(set) var contextReadBytes = 0
    public private(set) var outputBytes = 0

    public init(budget: RLMRunBudget, startedAt: Duration) {
        self.budget = budget
        self.startedAt = startedAt
    }

    public var remaining: RLMRunBudgetRemaining {
        RLMRunBudgetRemaining(
            rootIterations: max(0, budget.maxRootIterations - rootIterations),
            leafModelCalls: max(0, budget.maxLeafModelCalls - leafModelCalls),
            estimatedModelTokens: max(0, budget.maxEstimatedModelTokens - estimatedModelTokens),
            contextReadBytes: max(0, budget.maxCorpusBytesRead - contextReadBytes),
            outputBytes: max(0, budget.maxSchemeOutputBytes - outputBytes)
        )
    }

    public mutating func consumeRootIteration() throws {
        guard rootIterations < budget.maxRootIterations else {
            throw RLMFailure.rootIterationLimitReached(limit: budget.maxRootIterations)
        }
        rootIterations += 1
    }

    public mutating func consumeLeafModelCalls(_ count: Int) throws {
        guard count >= 0 else {
            throw RLMFailure.invalidToolArguments("leaf call count must not be negative")
        }
        guard leafModelCalls + count <= budget.maxLeafModelCalls else {
            throw RLMFailure.leafCallLimitReached(limit: budget.maxLeafModelCalls)
        }
        leafModelCalls += count
    }

    public mutating func consumeEstimatedModelTokens(_ count: Int) throws {
        guard count >= 0 else {
            throw RLMFailure.invalidToolArguments("token count must not be negative")
        }
        guard estimatedModelTokens + count <= budget.maxEstimatedModelTokens else {
            throw RLMFailure.tokenLimitReached(limit: budget.maxEstimatedModelTokens)
        }
        estimatedModelTokens += count
    }

    public mutating func consumeContextRead(bytes: Int) throws {
        guard bytes >= 0 else {
            throw RLMFailure.invalidToolArguments("context byte count must not be negative")
        }
        guard contextReadBytes + bytes <= budget.maxCorpusBytesRead else {
            throw RLMFailure.contextReadLimitReached(limit: budget.maxCorpusBytesRead)
        }
        contextReadBytes += bytes
    }

    public mutating func consumeOutput(bytes: Int) throws {
        guard bytes >= 0 else {
            throw RLMFailure.invalidToolArguments("output byte count must not be negative")
        }
        guard outputBytes + bytes <= budget.maxSchemeOutputBytes else {
            throw RLMFailure.outputLimitReached(limit: budget.maxSchemeOutputBytes)
        }
        outputBytes += bytes
    }

    public func checkWallTime(now: Duration) throws {
        guard now - startedAt < budget.maxWallDuration else {
            throw RLMFailure.wallTimeLimitReached(limit: budget.maxWallDuration)
        }
    }
}
