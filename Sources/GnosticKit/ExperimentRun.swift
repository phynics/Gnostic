// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The operating configuration one run records: its backend kind, selected
/// modules and their versions, model tiers, and policies.
///
/// It is a value (CONTEXT.md "Regime"), not a Node manifest object. The
/// manifest envelope already encodes it; a named regime profile is deferred
/// until a run compares regimes.
public struct ExperimentRegime: Codable, Sendable, Equatable {
    /// The Ascendant backend kind, for example `positronic`.
    public let backendKind: String
    /// The selected module names.
    public let modules: [String]
    /// The selected modules' versions, keyed by module name.
    ///
    /// Modules are compiled in, so a version is the registry id plus the
    /// repository revision that built it.
    public let moduleVersions: [String: String]
    /// The model names by tier (`primary`, `utility`, `fast`).
    public let modelTiers: [String: String]
    /// The provider name.
    public let provider: String
    /// The provider endpoint.
    public let endpoint: String
    /// Free-form policy fields that affect a run.
    public let policies: [String: String]

    /// Creates a regime record.
    public init(
        backendKind: String,
        modules: [String] = [],
        moduleVersions: [String: String] = [:],
        modelTiers: [String: String] = [:],
        provider: String = "",
        endpoint: String = "",
        policies: [String: String] = [:]
    ) {
        self.backendKind = backendKind
        self.modules = modules
        self.moduleVersions = moduleVersions
        self.modelTiers = modelTiers
        self.provider = provider
        self.endpoint = endpoint
        self.policies = policies
    }
}

/// The fixed parameters of one experiment round.
///
/// Every run in the round shares them; an artifact whose manifest differs
/// cannot be resumed (the void-round rule).
public struct ExperimentRunManifest: Codable, Sendable, Equatable {
    /// The experiment id, for example `rlm-scenario-manifest-v1`.
    public let manifestID: String
    /// The experiment version.
    public let manifestVersion: String
    /// The round segment, for example `pilot` or `matrix`.
    public let segment: String
    /// The Regime the runs execute under.
    public let regime: ExperimentRegime
    /// The repository commit the run was built from.
    public let gitCommit: String
    /// Whether the working tree was clean.
    public let workingTreeClean: Bool
    /// The pinned container image, or nil for an explicitly unpinned host run.
    public let imageDigest: String?
    /// The host, as `operatingSystem/architecture`.
    public let host: String
    /// The sampling parameters, as text (the adapter sets none).
    public let samplingParameters: String
    /// The run budget.
    public let budget: ExperimentBudget
    /// The frozen case set digest.
    public let caseSetSHA256: String
    /// A digest of the corpus revision, when the experiment has one.
    public let corpusRevisionDigest: String?
    /// The selected case IDs.
    public let caseIDs: [String]
    /// The selected arms, in execution order.
    public let arms: [String]
    /// Repetitions per case and arm.
    public let repetitions: Int
    /// Provider rates, or nil for a flat-rate subscription.
    public let pricing: ExperimentPricing?

    /// Creates a run manifest.
    public init(
        manifestID: String,
        manifestVersion: String,
        segment: String,
        regime: ExperimentRegime,
        gitCommit: String,
        workingTreeClean: Bool,
        imageDigest: String?,
        host: String,
        samplingParameters: String,
        budget: ExperimentBudget,
        caseSetSHA256: String,
        corpusRevisionDigest: String?,
        caseIDs: [String],
        arms: [String],
        repetitions: Int,
        pricing: ExperimentPricing?
    ) {
        self.manifestID = manifestID
        self.manifestVersion = manifestVersion
        self.segment = segment
        self.regime = regime
        self.gitCommit = gitCommit
        self.workingTreeClean = workingTreeClean
        self.imageDigest = imageDigest
        self.host = host
        self.samplingParameters = samplingParameters
        self.budget = budget
        self.caseSetSHA256 = caseSetSHA256
        self.corpusRevisionDigest = corpusRevisionDigest
        self.caseIDs = caseIDs
        self.arms = arms
        self.repetitions = repetitions
        self.pricing = pricing
    }

    /// The fields that differ from another manifest, for a void-round message.
    public func differences(from other: Self) -> [String] {
        let pairs: [(String, Bool)] = [
            ("manifest", manifestID == other.manifestID && manifestVersion == other.manifestVersion),
            ("segment", segment == other.segment),
            ("regime", regime == other.regime),
            ("gitCommit", gitCommit == other.gitCommit),
            ("imageDigest", imageDigest == other.imageDigest),
            ("host", host == other.host),
            ("samplingParameters", samplingParameters == other.samplingParameters),
            ("budget", budget == other.budget),
            ("caseSet", caseSetSHA256 == other.caseSetSHA256),
            ("corpusRevision", corpusRevisionDigest == other.corpusRevisionDigest),
            ("cases", caseIDs == other.caseIDs),
            ("arms", arms == other.arms),
            ("repetitions", repetitions == other.repetitions),
            ("pricing", pricing == other.pricing),
        ]
        return pairs.filter { !$0.1 }.map(\.0)
    }

    /// Whether a pilot and a matrix ran the same comparison: everything but the
    /// segment and the case selection must match.
    public func sharesComparison(with pilot: Self) -> [String] {
        differences(from: pilot).filter { !["segment", "cases", "repetitions"].contains($0) }
    }
}

/// The bounded work one run may perform.
public struct ExperimentBudget: Codable, Sendable, Equatable {
    /// Wall-clock bound, in seconds.
    public let wallDurationSeconds: Int64
    /// Model calls bound.
    public let modelCalls: Int
    /// Estimated token bound.
    public let estimatedModelTokens: Int
    /// Free-form additional bounds, for example corpus bytes.
    public let additional: [String: Int]

    /// Creates a budget description.
    public init(
        wallDurationSeconds: Int64,
        modelCalls: Int,
        estimatedModelTokens: Int,
        additional: [String: Int] = [:]
    ) {
        self.wallDurationSeconds = wallDurationSeconds
        self.modelCalls = modelCalls
        self.estimatedModelTokens = estimatedModelTokens
        self.additional = additional
    }
}

/// One planned run.
public struct ExperimentRunKey: Hashable, Sendable, Codable {
    /// The case ID.
    public let caseID: String
    /// The arm, for example an executor or regime arm.
    public let arm: String
    /// The repetition number, starting at 1.
    public let repetition: Int

    /// Creates one run key.
    public init(caseID: String, arm: String, repetition: Int) {
        self.caseID = caseID
        self.arm = arm
        self.repetition = repetition
    }
}

/// One evidence reference a run cited.
public struct ExperimentEvidence: Codable, Sendable, Equatable {
    /// An opaque identifier, for example a corpus chunk ID.
    public let id: String
    /// The source path.
    public let path: String
    /// The first line, inclusive.
    public let startLine: Int
    /// The last line, inclusive.
    public let endLine: Int

    /// Creates one evidence reference.
    public init(id: String, path: String, startLine: Int, endLine: Int) {
        self.id = id
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }
}

/// Named numeric observations from one run.
///
/// An experiment names its own metrics; the kit only aggregates and records
/// them, so a new experiment needs no run-record change.
public struct ExperimentRunMetrics: Codable, Sendable, Equatable {
    /// The metric values by name.
    public var values: [String: Double]

    /// Creates a metric set.
    public init(values: [String: Double] = [:]) {
        self.values = values
    }

    /// One metric value by name.
    public subscript(name: String) -> Double? { values[name] }
}

/// The recorded result of one run.
public struct ExperimentRunRecord: Codable, Sendable, Equatable {
    /// The case ID.
    public let caseID: String
    /// The arm.
    public let arm: String
    /// The repetition number.
    public let repetition: Int
    /// The start time, ISO-8601.
    public let startedAtUTC: String
    /// `completed`, `failed`, `cancelled`, or `fenced`.
    public let outcome: String
    /// A structured failure category, when the run failed.
    public let failureCategory: String?
    /// The failure detail, when the run failed.
    public let failure: String?
    /// The answer text, when the run completed.
    public let answer: String?
    /// The cited evidence.
    public let evidence: [ExperimentEvidence]
    /// A digest of the source revision the run captured, when available.
    public let sourceRevisionDigest: String?
    /// The wall time, in milliseconds.
    public let wallMilliseconds: Double
    /// The run's named metrics.
    public let metrics: ExperimentRunMetrics
    /// The root model usage.
    public let rootUsage: ExperimentUsage
    /// The leaf (or tool) model usage.
    public let leafUsage: ExperimentUsage
    /// The run cost in USD, at the round's rates.
    public let costUSD: Double
    /// False when a provider omitted usage for any call, so cost is a lower bound.
    public let costComplete: Bool
    /// The quality score, when a scorer assigned one.
    public var score: Int?

    /// Creates one run record.
    public init(
        caseID: String,
        arm: String,
        repetition: Int,
        startedAtUTC: String,
        outcome: String,
        failureCategory: String? = nil,
        failure: String?,
        answer: String?,
        evidence: [ExperimentEvidence],
        sourceRevisionDigest: String?,
        wallMilliseconds: Double,
        metrics: ExperimentRunMetrics,
        rootUsage: ExperimentUsage,
        leafUsage: ExperimentUsage,
        costUSD: Double,
        costComplete: Bool,
        score: Int? = nil
    ) {
        self.caseID = caseID
        self.arm = arm
        self.repetition = repetition
        self.startedAtUTC = startedAtUTC
        self.outcome = outcome
        self.failureCategory = failureCategory
        self.failure = failure
        self.answer = answer
        self.evidence = evidence
        self.sourceRevisionDigest = sourceRevisionDigest
        self.wallMilliseconds = wallMilliseconds
        self.metrics = metrics
        self.rootUsage = rootUsage
        self.leafUsage = leafUsage
        self.costUSD = costUSD
        self.costComplete = costComplete
        self.score = score
    }

    /// The run's key.
    public var key: ExperimentRunKey {
        ExperimentRunKey(caseID: caseID, arm: arm, repetition: repetition)
    }

    /// The run's total usage.
    public var totalUsage: ExperimentUsage { rootUsage + leafUsage }
}

/// Worst-case ceilings a round cannot exceed, computed before any spend.
public struct ExperimentCeiling: Codable, Sendable, Equatable {
    /// The number of runs.
    public let runs: Int
    /// The maximum model calls.
    public let maximumModelCalls: Int
    /// The estimated token bound (a character estimate, not provider tokens).
    public let maximumEstimatedTokens: Int
    /// The maximum estimated cost in USD, or nil when the round is unpriced.
    public let maximumEstimatedCostUSD: Double?

    /// Creates a ceiling.
    public init(runs: Int, budget: ExperimentBudget, pricing: ExperimentPricing?) {
        self.runs = runs
        maximumModelCalls = runs * budget.modelCalls
        maximumEstimatedTokens = runs * budget.estimatedModelTokens
        let tokens = Double(maximumEstimatedTokens)
        maximumEstimatedCostUSD = pricing.map {
            tokens * max($0.inputUSDPerMillionTokens, $0.outputUSDPerMillionTokens) / 1_000_000
        }
    }
}

/// Measured per-arm means from a pilot, projected to the full comparison.
public struct ExperimentProjection: Codable, Sendable, Equatable {
    /// One arm's projection.
    public struct Arm: Codable, Sendable, Equatable {
        /// The arm.
        public let arm: String
        /// The number of measured runs.
        public let measuredRuns: Int
        /// The mean model calls per run.
        public let meanModelCalls: Double
        /// The mean prompt tokens per run.
        public let meanPromptTokens: Double
        /// The mean completion tokens per run.
        public let meanCompletionTokens: Double
        /// The mean cost per run.
        public let meanCostUSD: Double
        /// The projected run count.
        public let projectedRuns: Int
        /// The projected cost.
        public let projectedCostUSD: Double

        /// Creates one arm projection.
        public init(
            arm: String,
            measuredRuns: Int,
            meanModelCalls: Double,
            meanPromptTokens: Double,
            meanCompletionTokens: Double,
            meanCostUSD: Double,
            projectedRuns: Int,
            projectedCostUSD: Double
        ) {
            self.arm = arm
            self.measuredRuns = measuredRuns
            self.meanModelCalls = meanModelCalls
            self.meanPromptTokens = meanPromptTokens
            self.meanCompletionTokens = meanCompletionTokens
            self.meanCostUSD = meanCostUSD
            self.projectedRuns = projectedRuns
            self.projectedCostUSD = projectedCostUSD
        }
    }

    /// The basis of the projection.
    public let basis: String
    /// The per-arm projections.
    public let arms: [Arm]
    /// The projected total runs.
    public let projectedRuns: Int
    /// The projected total cost.
    public let projectedCostUSD: Double
    /// False when some measured runs reported incomplete usage.
    public let costComplete: Bool

    /// Projects a pilot's measured means to a full comparison.
    public static func project(
        runs: [ExperimentRunRecord],
        casesInComparison: Int,
        repetitions: Int
    ) -> Self {
        let perArmRuns = casesInComparison * repetitions
        let arms = Dictionary(grouping: runs, by: \.arm).keys.sorted().map { name in
            let records = runs.filter { $0.arm == name }
            let count = Double(records.count)
            let usage = records.map(\.totalUsage).reduce(ExperimentUsage(), +)
            let meanCost = records.map(\.costUSD).reduce(0, +) / count
            return Arm(
                arm: name,
                measuredRuns: records.count,
                meanModelCalls: Double(usage.calls) / count,
                meanPromptTokens: Double(usage.promptTokens) / count,
                meanCompletionTokens: Double(usage.completionTokens) / count,
                meanCostUSD: meanCost,
                projectedRuns: perArmRuns,
                projectedCostUSD: meanCost * Double(perArmRuns)
            )
        }
        return Self(
            basis: "pilot means per arm × \(casesInComparison) cases × \(repetitions) repetition(s)",
            arms: arms,
            projectedRuns: arms.reduce(0) { $0 + $1.projectedRuns },
            projectedCostUSD: arms.reduce(0) { $0 + $1.projectedCostUSD },
            costComplete: runs.allSatisfy(\.costComplete)
        )
    }
}

/// A pilot a larger comparison was authorised from.
public struct ExperimentPilotReference: Codable, Sendable, Equatable {
    /// The pilot artifact path, as given.
    public let path: String
    /// The pilot artifact's SHA-256.
    public let sha256: String
    /// The pilot's measured projection.
    public let projection: ExperimentProjection

    /// Creates a pilot reference.
    public init(path: String, sha256: String, projection: ExperimentProjection) {
        self.path = path
        self.sha256 = sha256
        self.projection = projection
    }
}

/// One measurement's status in a round.
public struct ExperimentMeasurementStatus: Codable, Sendable, Equatable {
    /// The measurement id.
    public let id: String
    /// The status.
    public let status: String
    /// The reason.
    public let reason: String

    /// Creates one measurement status.
    public init(id: String, status: String, reason: String) {
        self.id = id
        self.status = status
        self.reason = reason
    }
}

/// The resumable round artifact.
///
/// It is rewritten after every run, so a round can stop and resume.
public struct ExperimentRunArtifact: Codable, Sendable, Equatable {
    /// The artifact schema version.
    public let schemaVersion: Int
    /// The round manifest.
    public let manifest: ExperimentRunManifest
    /// `in-progress`, `complete`, or `stopped-at-cost-ceiling`.
    public var status: String
    /// The last update time, ISO-8601.
    public var updatedAtUTC: String
    /// The worst-case ceiling.
    public let ceiling: ExperimentCeiling
    /// The authorised cost ceiling, when the round is priced.
    public let authorisedMaximumCostUSD: Double?
    /// The pilot authorising a larger comparison, when present.
    public let pilot: ExperimentPilotReference?
    /// The scoring rule in force.
    public let scoringRule: String
    /// Measurements that are unavailable or require a later step.
    public let measurements: [ExperimentMeasurementStatus]
    /// The recorded runs.
    public var runs: [ExperimentRunRecord]
    /// The actual cost so far.
    public var costActualUSD: Double
    /// False when some run reported incomplete usage.
    public var costComplete: Bool
    /// Present on a complete pilot: the measured projection.
    public var costProjection: ExperimentProjection?

    /// Creates a round artifact.
    public init(
        schemaVersion: Int,
        manifest: ExperimentRunManifest,
        status: String,
        updatedAtUTC: String,
        ceiling: ExperimentCeiling,
        authorisedMaximumCostUSD: Double?,
        pilot: ExperimentPilotReference?,
        scoringRule: String,
        measurements: [ExperimentMeasurementStatus],
        runs: [ExperimentRunRecord],
        costActualUSD: Double,
        costComplete: Bool,
        costProjection: ExperimentProjection? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.manifest = manifest
        self.status = status
        self.updatedAtUTC = updatedAtUTC
        self.ceiling = ceiling
        self.authorisedMaximumCostUSD = authorisedMaximumCostUSD
        self.pilot = pilot
        self.scoringRule = scoringRule
        self.measurements = measurements
        self.runs = runs
        self.costActualUSD = costActualUSD
        self.costComplete = costComplete
        self.costProjection = costProjection
    }
}

/// Reads and writes a round artifact as JSON.
public enum ExperimentArtifactFile {
    /// Reads an artifact, or nil when the path does not exist.
    public static func read(_ url: URL) throws -> ExperimentRunArtifact? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExperimentRunArtifact.self, from: Data(contentsOf: url))
    }

    /// Writes an artifact, creating parent directories, with a trailing newline.
    public static func write(_ artifact: ExperimentRunArtifact, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(artifact)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Loads a pilot and checks it can authorise a comparison with `manifest`.
    public static func authorisingPilot(
        at url: URL,
        displayPath: String,
        for manifest: ExperimentRunManifest
    ) throws -> ExperimentPilotReference {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ExperimentError.missingPilot("no pilot artifact at \(displayPath)")
        }
        let pilot = try JSONDecoder().decode(ExperimentRunArtifact.self, from: data)
        guard pilot.manifest.segment == "pilot", pilot.status == "complete", let projection = pilot.costProjection else {
            throw ExperimentError.missingPilot("\(displayPath) is not a complete pilot with a cost projection")
        }
        let differences = manifest.sharesComparison(with: pilot.manifest)
        guard differences.isEmpty else {
            throw ExperimentError.missingPilot("the pilot ran a different comparison (\(differences.joined(separator: ", ")))")
        }
        return ExperimentPilotReference(path: displayPath, sha256: ExperimentDigest.sha256Hex([UInt8](data)), projection: projection)
    }
}
