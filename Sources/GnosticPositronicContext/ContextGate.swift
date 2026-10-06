// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit

/// One arm of the offline context hypothesis gate.
public enum ContextGateArm: String, Codable, Sendable, Equatable, CaseIterable {
    /// The whole transcript, unbounded.
    case rawHistory = "raw-history"
    /// PositronicKit prompt-budget compression with a small window.
    case pkCompression = "pk-compression"
    /// A single head-plus-tail summary of the whole history.
    case oneShotSummary = "one-shot-summary"
    /// Incremental leaves, then a flat checkpoint.
    case incrementalFlat = "incremental-flat"
    /// A hierarchical mixed-resolution cover, then a checkpoint.
    case hierarchicalCover = "hierarchical-cover"
}

/// The recommended gate decision.
public enum ContextGateDecision: String, Codable, Sendable, Equatable {
    /// Curation beats the baselines. Unblock the post-gate children.
    case proceed = "PROCEED"
    /// Part of the design pays off. Amend the epic.
    case simplify = "SIMPLIFY"
    /// The result is close. Name what is still uncertain.
    case continueExperiment = "CONTINUE_EXPERIMENT"
    /// Curation did not pay off. Close the post-gate children as not planned.
    case archive = "ARCHIVE"
}

/// The scored numbers for one gate arm.
public struct ContextGateArmResult: Codable, Sendable, Equatable {
    /// The arm.
    public let arm: ContextGateArm
    /// The checks the projection passed.
    public let checksPassed: Int
    /// The checks the projection was scored against.
    public let checksTotal: Int
    /// Overall recall in `0...1`.
    public let recall: Double
    /// Recall per obligation class.
    public let recallByObligation: [String: Double]
    /// The number of curator model calls.
    public let curatorCalls: Int
    /// The estimated input tokens.
    public let inputTokens: Int
    /// The estimated output tokens.
    public let outputTokens: Int
    /// The projection size in characters.
    public let projectionCharacters: Int
}

/// The offline gate result: five scored arms and one recommended decision.
public struct ContextGateResult: Codable, Sendable, Equatable {
    /// The arm results, in gate order.
    public let arms: [ContextGateArmResult]
    /// The recommended decision.
    public let decision: ContextGateDecision
    /// The rationale for the recommendation.
    public let rationale: String
    /// The curation arm the recommendation is based on.
    public let bestCurationArm: ContextGateArm?

    /// Encodes the result as sorted, pretty JSON.
    ///
    /// - Returns: The JSON data.
    /// - Throws: An encoding error.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Renders the decision record as Markdown.
    ///
    /// - Returns: The Markdown document.
    public func markdown() -> String {
        var lines = [
            "# Context hypothesis gate",
            "",
            "Offline gate for the Positronic semantic context compiler experiment (#426, GNO-CTX-006).",
            "Every arm runs through the deterministic fixture seam. No provider is contacted.",
            "",
            "## Decision",
            "",
            "**\(decision.rawValue)**. \(rationale)",
            "",
            "## Numbers",
            "",
            "| Arm | Recall | Checks | Curator calls | Input tokens | Output tokens | Projection chars |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        for arm in arms {
            lines.append(
                "| \(arm.arm.rawValue) | \(Self.percent(arm.recall)) | \(arm.checksPassed)/\(arm.checksTotal) | "
                    + "\(arm.curatorCalls) | \(arm.inputTokens) | \(arm.outputTokens) | \(arm.projectionCharacters) |"
            )
        }
        lines.append("")
        lines.append("## Recall by obligation")
        lines.append("")
        let obligations = Set(arms.flatMap { $0.recallByObligation.keys }).sorted()
        lines.append("| Obligation | " + arms.map(\.arm.rawValue).joined(separator: " | ") + " |")
        lines.append("| --- | " + arms.map { _ in "---" }.joined(separator: " | ") + " |")
        for obligation in obligations {
            let values = arms.map { arm in
                arm.recallByObligation[obligation].map(Self.percent) ?? "n/a"
            }
            lines.append("| \(obligation) | " + values.joined(separator: " | ") + " |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A one-line summary for a terminal.
    ///
    /// - Returns: The summary line.
    public func summary() -> String {
        "Context gate: \(decision.rawValue). " + arms.map { "\($0.arm.rawValue) \(Self.percent($0.recall))" }.joined(separator: ", ")
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// The curation products the two curation arms project.
struct ContextGateCuration: Sendable {
    /// The flat checkpoint projection.
    let flat: String
    /// The hierarchical mixed-resolution cover projection.
    let cover: String
    /// The number of curator calls the replay made.
    let curatorCalls: Int
    /// The built hierarchy.
    let hierarchy: ContextHierarchy
}

/// Scores the five gate arms against the shared planted obligations.
///
/// The driver is the offline stand-in for a model: each arm's projection *is*
/// the model-facing context and is scored as the answer. The two curation arms
/// run the real replay, validation, commit, and hierarchy code, so the gate
/// measures the design, not a mock of it.
public struct ContextGateDriver: ExperimentScenarioDriver {
    /// The benchmark cases, one per shared planted obligation.
    public let cases: [ExperimentScenarioCase]
    /// The five gate arms.
    public let arms: [String]
    /// The long-horizon transcript.
    public let transcript: ContextTranscript
    /// The checks each case scores, keyed by case ID.
    public let checksByCaseID: [String: [ExperimentScenarioCheck]]
    /// The host-owned bounds.
    public let descriptor: ContextDescriptor
    /// The number of messages in one episode.
    public let episodeSize: Int
    /// How many of the root's most recent children stay at leaf resolution.
    public let recentParents: Int
    /// The PositronicKit token budget for the `pk-compression` arm.
    public let pkBudgetTokens: Int

    /// Creates the gate driver.
    ///
    /// - Parameters:
    ///   - transcript: The long-horizon transcript.
    ///   - cases: The benchmark cases.
    ///   - checksByCaseID: The checks each case scores.
    ///   - descriptor: The host-owned bounds.
    ///   - episodeSize: The number of messages in one episode.
    ///   - recentParents: How many recent root children stay at leaf resolution.
    ///   - pkBudgetTokens: The PositronicKit token budget.
    public init(
        transcript: ContextTranscript = ContextFixtureTranscript.longHorizon(),
        cases: [ExperimentScenarioCase] = ContextFixtureTranscript.cases,
        checksByCaseID: [String: [ExperimentScenarioCheck]] = ContextFixtureTranscript.checksByCaseID,
        descriptor: ContextDescriptor = .default,
        episodeSize: Int = 2,
        recentParents: Int = 1,
        pkBudgetTokens: Int = ContextPKCompression.defaultBudgetTokens
    ) {
        self.transcript = transcript
        self.cases = cases
        self.checksByCaseID = checksByCaseID
        self.descriptor = descriptor
        self.episodeSize = episodeSize
        self.recentParents = recentParents
        self.pkBudgetTokens = pkBudgetTokens
        self.arms = ContextGateArm.allCases.map(\.rawValue)
    }

    public func run(_ scenarioCase: ExperimentScenarioCase, key: ExperimentRunKey) async -> ExperimentRunRecord {
        let curation = (try? await curation()) ?? ContextGateCuration(flat: "", cover: "", curatorCalls: 0, hierarchy: ContextHierarchy(levels: []))
        let projection = projection(for: key.arm, curation: curation)
        let checks = checksByCaseID[scenarioCase.id] ?? []
        let score = ExperimentAssertionScorer().score(answer: projection, checks: checks)
        return ExperimentRunRecord(
            caseID: scenarioCase.id,
            arm: key.arm,
            repetition: key.repetition,
            startedAtUTC: "1970-01-01T00:00:00Z",
            outcome: "completed",
            failureCategory: nil,
            failure: nil,
            answer: projection,
            evidence: [],
            sourceRevisionDigest: nil,
            wallMilliseconds: 0,
            metrics: ExperimentRunMetrics(values: [
                "checksPassed": Double(score.passed),
                "checksTotal": Double(score.total),
                "recall": score.overallRecall ?? 0,
                "projectionCharacters": Double(projection.count),
            ]),
            rootUsage: ExperimentUsage(),
            leafUsage: ExperimentUsage(),
            costUSD: 0,
            costComplete: true,
            score: score.passed
        )
    }

    /// Returns the projection for one arm.
    ///
    /// - Parameters:
    ///   - arm: The arm name.
    ///   - curation: The precomputed curation products.
    /// - Returns: The projection.
    func projection(for arm: String, curation: ContextGateCuration) -> String {
        switch ContextGateArm(rawValue: arm) {
        case .rawHistory:
            transcript.rendered
        case .pkCompression:
            (try? ContextPKCompression.project(transcript, budgetTokens: pkBudgetTokens)) ?? ""
        case .oneShotSummary:
            ContextOneShotSummary.project(transcript)
        case .incrementalFlat:
            curation.flat
        case .hierarchicalCover:
            curation.cover
        case nil:
            ""
        }
    }

    /// Runs the replay, validation, commit, and hierarchy for the curation arms.
    ///
    /// - Returns: The curation products.
    /// - Throws: A `ContextError` when a proposal fails validation.
    func curation() async throws -> ContextGateCuration {
        let timelineID = "tl-gate"
        let replay = ContextEpisodeReplay(timelineID: timelineID, episodeSize: episodeSize)
        let leaves = try await replay.replay(transcript: transcript, descriptor: descriptor, curator: FixtureContextCurator())
        let validator = ContextProposalValidator(descriptor: descriptor)
        var active = ContextCarryState()
        var nodes: [ContextNode] = []
        for leaf in leaves {
            let node = try validator.validate(leaf, expectedTimelineID: timelineID, activeCarry: active)
            nodes.append(node)
            active = ContextCarryState(items: active.items + node.carry.items)
        }
        let hierarchy = ContextHierarchyBuilder(descriptor: descriptor).build(leaves: nodes, timelineID: timelineID)
        let flat = ContextCarryReducer().reduce(nodes.map(\.carry)).activeItems.map(\.text).joined(separator: "\n")
        let cover = mixedResolutionCover(hierarchy).map(\.text).joined(separator: "\n")
        return ContextGateCuration(flat: flat, cover: cover, curatorCalls: leaves.count, hierarchy: hierarchy)
    }

    /// Selects a mixed-resolution cover of the hierarchy.
    ///
    /// Older regions stay at parent resolution; the most recent regions expand
    /// to leaf resolution. The cover is exact: every leaf belongs to exactly one
    /// selected node.
    ///
    /// - Parameter hierarchy: The hierarchy.
    /// - Returns: The active carry items of the selected nodes, in order.
    func mixedResolutionCover(_ hierarchy: ContextHierarchy) -> [ContextCarryItem] {
        guard let root = hierarchy.root else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: hierarchy.nodes.map { ($0.id, $0) })
        let children = root.children.compactMap { byID[$0] }
        guard children.count > 1 else {
            return children.flatMap { $0.carry.activeItems }
        }
        let split = max(0, children.count - recentParents)
        var selected = Array(children.prefix(split))
        for parent in children.suffix(recentParents) {
            let grandchildren = parent.children.compactMap { byID[$0] }
            selected.append(contentsOf: grandchildren.isEmpty ? [parent] : grandchildren)
        }
        selected.sort { ($0.coverage.firstMessageID ?? "") < ($1.coverage.firstMessageID ?? "") }
        return selected.flatMap { $0.carry.activeItems }
    }
}

/// Runs the offline hypothesis gate and recommends a decision.
public struct ContextGate: Sendable {
    /// The gate driver.
    public let driver: ContextGateDriver

    /// Creates a gate.
    ///
    /// - Parameter driver: The gate driver.
    public init(driver: ContextGateDriver = ContextGateDriver()) {
        self.driver = driver
    }

    /// Runs every arm and recommends a decision.
    ///
    /// - Returns: The gate result.
    /// - Throws: A `ContextError` when a curation arm fails.
    public func run() async throws -> ContextGateResult {
        let curation = try await driver.curation()
        var arms: [ContextGateArmResult] = []
        for arm in ContextGateArm.allCases {
            let projection = driver.projection(for: arm.rawValue, curation: curation)
            let score = driver.score(projection: projection)
            let calls: Int
            switch arm {
            case .oneShotSummary:
                calls = 1
            case .incrementalFlat, .hierarchicalCover:
                calls = curation.curatorCalls
            case .rawHistory, .pkCompression:
                calls = 0
            }
            arms.append(ContextGateArmResult(
                arm: arm,
                checksPassed: score.passed,
                checksTotal: score.total,
                recall: score.overallRecall ?? 0,
                recallByObligation: Dictionary(uniqueKeysWithValues: score.recallByObligation.map { ($0.key.rawValue, $0.value) }),
                curatorCalls: calls,
                inputTokens: projection.count / 4,
                outputTokens: 0,
                projectionCharacters: projection.count
            ))
        }
        let best = Self.bestCuration(arms)
        let (decision, rationale) = Self.decide(arms)
        return ContextGateResult(arms: arms, decision: decision, rationale: rationale, bestCurationArm: best?.arm)
    }

    /// The highest-recall curation arm, breaking ties by smaller projection.
    static func bestCuration(_ arms: [ContextGateArmResult]) -> ContextGateArmResult? {
        arms
            .filter { $0.arm == .incrementalFlat || $0.arm == .hierarchicalCover }
            .max { lhs, rhs in
                if lhs.recall != rhs.recall { return lhs.recall < rhs.recall }
                return lhs.projectionCharacters > rhs.projectionCharacters
            }
    }

    /// Recommends a decision from the scored arms.
    static func decide(_ arms: [ContextGateArmResult]) -> (ContextGateDecision, String) {
        guard let raw = arms.first(where: { $0.arm == .rawHistory }), let best = bestCuration(arms) else {
            return (.continueExperiment, "No baseline or curation arm was scored.")
        }
        let rawRecall = raw.recall
        let bestRecall = best.recall
        let rawPercent = ContextGateResult.percent(rawRecall)
        let bestPercent = ContextGateResult.percent(bestRecall)
        if bestRecall > rawRecall {
            let curationArms = arms.filter { $0.arm == .incrementalFlat || $0.arm == .hierarchicalCover }
            if let flat = curationArms.first(where: { $0.arm == .incrementalFlat }),
               let cover = curationArms.first(where: { $0.arm == .hierarchicalCover }),
               flat.recall == cover.recall,
               flat.projectionCharacters == cover.projectionCharacters {
                return (
                    .simplify,
                    "Flat leaf carry reaches \(ContextGateResult.percent(flat.recall)) recall at \(flat.projectionCharacters) characters and beats raw history \(rawPercent), "
                        + "but the hierarchical cover is identical (\(cover.projectionCharacters) characters). Keep the flat carry; drop the hierarchy from the epic."
                )
            }
            return (
                .proceed,
                "\(best.arm.rawValue) recall \(bestPercent) exceeds raw history \(rawPercent) with \(best.projectionCharacters) projection characters versus \(raw.projectionCharacters)."
            )
        }
        if bestRecall == rawRecall {
            return best.projectionCharacters <= raw.projectionCharacters
                ? (.proceed, "\(best.arm.rawValue) matches raw history recall \(rawPercent) with fewer projection characters (\(best.projectionCharacters) versus \(raw.projectionCharacters)).")
                : (.simplify, "\(best.arm.rawValue) matches raw history recall \(rawPercent) but uses more projection characters (\(best.projectionCharacters) versus \(raw.projectionCharacters)).")
        }
        if rawRecall - bestRecall <= 0.15 {
            return (
                .continueExperiment,
                "\(best.arm.rawValue) recall \(bestPercent) trails raw history \(rawPercent); the gap is close enough to keep experimenting."
            )
        }
        return (.archive, "\(best.arm.rawValue) recall \(bestPercent) trails raw history \(rawPercent); curation did not pay off.")
    }
}

extension ContextGateDriver {
    /// Scores one projection against every case.
    ///
    /// - Parameter projection: The projection.
    /// - Returns: The aggregated score.
    func score(projection: String) -> ExperimentScore {
        var results: [ExperimentCheckResult] = []
        for scenarioCase in cases {
            let checks = checksByCaseID[scenarioCase.id] ?? []
            results.append(contentsOf: ExperimentAssertionScorer().score(answer: projection, checks: checks).results)
        }
        return ExperimentScore(results: results)
    }
}
