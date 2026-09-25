// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM

/// Manifest §8 live stages.
enum RLMScenarioStage: String, Codable, Sendable, CaseIterable {
    /// Stage 2: one question, both executors.
    case pilot
    /// Stage 3: the chosen questions (all 12 by default), both executors.
    case matrix

    var defaultArtifactPath: String {
        switch self {
        case .pilot: "Documentation/Experiments/rlm-scenario-stage2.json"
        case .matrix: "Documentation/Experiments/rlm-scenario-stage3.json"
        }
    }
}

/// The manifest §1 fixed parameters of one round. Every run in a round shares
/// them; an artifact whose identity differs cannot be resumed (§7).
struct RLMScenarioRoundIdentity: Codable, Sendable, Equatable {
    /// Manifest v7: the owner accepted a light sample, one repetition by default.
    static let defaultRepetitions = 1
    static let maximumRepetitions = 3

    let manifestID: String
    let manifestVersion: String
    let stage: RLMScenarioStage
    let gitCommit: String
    let workingTreeClean: Bool
    /// The pinned container image, or nil for an explicitly unpinned host run.
    let imageDigest: String?
    let host: String
    let provider: String
    let endpoint: String
    let rootModel: String
    let leafModels: RLMScenarioLeafModels
    let samplingParameters: String
    let budget: RLMScenarioBudgetDescription
    let questionSetSHA256: String
    let corpusRevisionDigest: String
    let questionIDs: [String]
    let executors: [String]
    let repetitions: Int
    /// Nil for a flat-rate subscription: tokens are metered, dollars are not.
    let pricing: RLMScenarioPricing?

    /// The fields that differ from another identity, for a void-round message.
    func differences(from other: Self) -> [String] {
        let pairs: [(String, Bool)] = [
            ("manifest", manifestID == other.manifestID && manifestVersion == other.manifestVersion),
            ("stage", stage == other.stage),
            ("gitCommit", gitCommit == other.gitCommit),
            ("imageDigest", imageDigest == other.imageDigest),
            ("host", host == other.host),
            ("provider", provider == other.provider && endpoint == other.endpoint),
            ("rootModel", rootModel == other.rootModel),
            ("leafModels", leafModels == other.leafModels),
            ("samplingParameters", samplingParameters == other.samplingParameters),
            ("budget", budget == other.budget),
            ("questionSet", questionSetSHA256 == other.questionSetSHA256),
            ("corpusRevision", corpusRevisionDigest == other.corpusRevisionDigest),
            ("questions", questionIDs == other.questionIDs),
            ("executors", executors == other.executors),
            ("repetitions", repetitions == other.repetitions),
            ("pricing", pricing == other.pricing),
        ]
        return pairs.filter { !$0.1 }.map(\.0)
    }

    /// Whether a pilot and a matrix ran the same comparison: everything but the
    /// stage and the question selection must match.
    func sharesComparison(with pilot: Self) -> [String] {
        differences(from: pilot).filter { !["stage", "questions", "repetitions"].contains($0) }
    }
}

struct RLMScenarioLeafModels: Codable, Sendable, Equatable {
    let primary: String
    let utility: String
    let fast: String
}

struct RLMScenarioBudgetDescription: Codable, Sendable, Equatable {
    let wallDurationSeconds: Int64
    let rootIterations: Int
    let leafModelCalls: Int
    let estimatedModelTokens: Int
    let cellRepairs: Int
    let corpusBytesRead: Int
    let evidenceReferences: Int

    init(_ budget: RLMRunBudget) {
        wallDurationSeconds = budget.maxWallDuration.components.seconds
        rootIterations = budget.maxRootIterations
        leafModelCalls = budget.maxLeafModelCalls
        estimatedModelTokens = budget.maxEstimatedModelTokens
        cellRepairs = budget.maxCellRepairs
        corpusBytesRead = budget.maxCorpusBytesRead
        evidenceReferences = budget.maxEvidenceReferences
    }
}

/// One planned run.
struct RLMScenarioRunKey: Hashable, Sendable {
    let questionID: String
    let executor: String
    let repetition: Int
}

/// The recorded result of one live run.
struct RLMScenarioRunRecord: Codable, Sendable, Equatable {
    let questionID: String
    let executor: String
    let repetition: Int
    let startedAtUTC: String
    /// `completed`, `failed`, `cancelled`, or `fenced`.
    let outcome: String
    let failure: String?
    let answer: String?
    let evidence: [RLMScenarioEvidence]
    let snapshotRevisionDigest: String?
    let wallMilliseconds: Double
    let metrics: RLMScenarioRunMetrics
    let rootUsage: RLMScenarioUsage
    let leafUsage: RLMScenarioUsage
    let costUSD: Double
    /// False when a provider omitted usage for any call, so cost is a lower bound.
    let costComplete: Bool
    /// 0–10, set by `rlm-scenario-rating --apply-scores`; nil until rated.
    var score: Int?

    var key: RLMScenarioRunKey {
        RLMScenarioRunKey(questionID: questionID, executor: executor, repetition: repetition)
    }

    var totalUsage: RLMScenarioUsage { rootUsage + leafUsage }
}

struct RLMScenarioEvidence: Codable, Sendable, Equatable {
    let chunkID: String
    let path: String
    let startLine: Int
    let endLine: Int
}

struct RLMScenarioRunMetrics: Codable, Sendable, Equatable {
    let rootIterations: Int
    let rootCellRejections: Int
    let runtimeFailures: Int
    let repairs: Int
    let leafModelCalls: Int
    let leafPrompts: Int
    let corpusSearchCalls: Int
    let corpusReadCalls: Int
    let contextReadBytes: Int
    let estimatedModelTokens: Int
    let evidenceReferences: Int

    init(_ metrics: RLMRunMetrics) {
        rootIterations = metrics.rootIterations
        rootCellRejections = metrics.rootCellRejections
        runtimeFailures = metrics.runtimeFailures
        repairs = metrics.repairs
        leafModelCalls = metrics.leafModelCalls
        leafPrompts = metrics.leafPrompts
        corpusSearchCalls = metrics.corpusSearchCalls
        corpusReadCalls = metrics.corpusReadCalls
        contextReadBytes = metrics.contextReadBytes
        estimatedModelTokens = metrics.estimatedModelTokens
        evidenceReferences = metrics.evidenceReferences
    }
}

/// Manifest v7 §5: one answer-quality score per completed run.
enum RLMScenarioScoring {
    static let rule = "One score from 0 to 10 per completed run, assigned after collection by an LLM evaluator that sees the question, the reference answer, the run's answer, and its cited evidence, but not the executor (`gnostic experiment rlm-scenario-rating`)."
    static let range = 0...10
}

/// Worst-case ceilings a round cannot exceed, computed before any spend.
struct RLMScenarioCeiling: Codable, Sendable, Equatable {
    let runs: Int
    let maximumModelCalls: Int
    /// The host token estimator's bound. It is a character estimate, not
    /// provider tokens, so the dollar figure is an order-of-magnitude ceiling.
    let maximumEstimatedTokens: Int
    let maximumEstimatedCostUSD: Double?

    init(runs: Int, budget: RLMScenarioBudgetDescription, pricing: RLMScenarioPricing?) {
        self.runs = runs
        maximumModelCalls = runs * (budget.rootIterations + budget.leafModelCalls)
        maximumEstimatedTokens = runs * budget.estimatedModelTokens
        let tokens = Double(maximumEstimatedTokens)
        maximumEstimatedCostUSD = pricing.map {
            tokens * max($0.inputUSDPerMillionTokens, $0.outputUSDPerMillionTokens) / 1_000_000
        }
    }
}

/// Measured per-executor means from a pilot, projected to the full matrix.
struct RLMScenarioProjection: Codable, Sendable, Equatable {
    struct Executor: Codable, Sendable, Equatable {
        let executor: String
        let measuredRuns: Int
        let meanModelCalls: Double
        let meanPromptTokens: Double
        let meanCompletionTokens: Double
        let meanCostUSD: Double
        let projectedRuns: Int
        let projectedCostUSD: Double
    }

    let basis: String
    let executors: [Executor]
    let projectedRuns: Int
    let projectedCostUSD: Double
    let costComplete: Bool

    static func project(runs: [RLMScenarioRunRecord], questionsInMatrix: Int, repetitions: Int) -> Self {
        let perExecutorRuns = questionsInMatrix * repetitions
        let executors = Dictionary(grouping: runs, by: \.executor).keys.sorted().map { name in
            let records = runs.filter { $0.executor == name }
            let count = Double(records.count)
            let usage = records.map(\.totalUsage).reduce(RLMScenarioUsage(), +)
            let meanCost = records.map(\.costUSD).reduce(0, +) / count
            return Executor(
                executor: name,
                measuredRuns: records.count,
                meanModelCalls: Double(usage.calls) / count,
                meanPromptTokens: Double(usage.promptTokens) / count,
                meanCompletionTokens: Double(usage.completionTokens) / count,
                meanCostUSD: meanCost,
                projectedRuns: perExecutorRuns,
                projectedCostUSD: meanCost * Double(perExecutorRuns)
            )
        }
        return Self(
            basis: "Stage 2 pilot means per executor × \(questionsInMatrix) questions × \(repetitions) repetition(s). Arm D is unavailable and excluded.",
            executors: executors,
            projectedRuns: executors.reduce(0) { $0 + $1.projectedRuns },
            projectedCostUSD: executors.reduce(0) { $0 + $1.projectedCostUSD },
            costComplete: runs.allSatisfy(\.costComplete)
        )
    }
}

/// A pilot the matrix was authorised from.
struct RLMScenarioPilotReference: Codable, Sendable, Equatable {
    let path: String
    let sha256: String
    let projection: RLMScenarioProjection
}

/// The Stage 2 or Stage 3 artifact. It is rewritten after every run, so a
/// round can stop and resume.
struct RLMScenarioLiveArtifact: Codable, Sendable, Equatable {
    static let unavailableMeasurements = [
        RLMScenarioMeasurementStatus(id: "M7", status: "requires-rater", reason: "Each completed run's score is set after collection by the blind LLM evaluator (v7 §5)."),
        RLMScenarioMeasurementStatus(id: "M8", status: "unavailable", reason: "Arm D (ordinary Positronic Workspace analysis) has no headless runner, so M8 is not required (§2)."),
    ]

    let schemaVersion: Int
    let round: RLMScenarioRoundIdentity
    /// `in-progress`, `complete`, or `stopped-at-cost-ceiling`.
    var status: String
    var updatedAtUTC: String
    let ceiling: RLMScenarioCeiling
    let authorisedMaximumCostUSD: Double?
    let pilot: RLMScenarioPilotReference?
    let scoringRule: String
    let measurements: [RLMScenarioMeasurementStatus]
    var runs: [RLMScenarioRunRecord]
    var costActualUSD: Double
    var costComplete: Bool
    /// Present on a complete pilot: the measured projection §8 requires.
    var costProjection: RLMScenarioProjection?
}

struct RLMScenarioMeasurementStatus: Codable, Sendable, Equatable {
    let id: String
    let status: String
    let reason: String
}
