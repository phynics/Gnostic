// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The obligation classes the kit scores.
///
/// A case's checks name the class they test, so a round reports recall per
/// class rather than one opaque number.
public enum ExperimentObligation: String, Codable, Sendable, Equatable, CaseIterable {
    /// A fact must be recalled.
    case fact
    /// A negative constraint must be respected ("never use SQLite").
    case negativeConstraint = "negative-constraint"
    /// An exact value must be reproduced (a port, a timeout).
    case exactValue = "exact-value"
    /// A later value must supersede an earlier one (MQTT to Zenoh).
    case supersession
    /// A correction must replace an earlier value.
    case correction
    /// An open item must be carried (BUG-17).
    case openItem = "open-item"
    /// Tool evidence must be used.
    case toolEvidence = "tool-evidence"
    /// A back-reference to the system's own earlier reply must resolve.
    case backReference = "back-reference"
    /// Concurrent root use must not corrupt state.
    case concurrentRoot = "concurrent-root"
    /// Malicious tool text must be ignored.
    case maliciousToolText = "malicious-tool-text"
    /// Self-maintenance pressure must not degrade the answer.
    case selfMaintenance = "self-maintenance"
}

/// One assertion a check makes about a run's answer.
public enum ExperimentAssertion: Sendable {
    /// The answer contains `text`.
    case contains(String)
    /// The answer contains `text` when case and whitespace are ignored.
    case containsNormalized(String)
    /// The answer contains every one of `texts`.
    case containsAll([String])
    /// The answer does not contain `text`.
    case absent(String)
    /// The answer equals `text` after trimming.
    case equals(String)

    /// Whether the assertion holds for an answer.
    public func holds(for answer: String) -> Bool {
        switch self {
        case let .contains(text):
            answer.contains(text)
        case let .containsNormalized(text):
            Self.normalize(answer).contains(Self.normalize(text))
        case let .containsAll(texts):
            texts.allSatisfy { answer.contains($0) }
        case let .absent(text):
            !answer.contains(text)
        case let .equals(text):
            answer.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// One check a case asserts about a run.
public struct ExperimentScenarioCheck: Sendable {
    /// The check ID, unique within its case.
    public let id: String
    /// The obligation class the check tests.
    public let obligation: ExperimentObligation
    /// A human-readable description.
    public let description: String
    /// The assertion.
    public let assertion: ExperimentAssertion

    /// Creates one check.
    public init(id: String, obligation: ExperimentObligation, description: String, assertion: ExperimentAssertion) {
        self.id = id
        self.obligation = obligation
        self.description = description
        self.assertion = assertion
    }
}

/// The result of one check.
public struct ExperimentCheckResult: Codable, Sendable, Equatable {
    /// The check ID.
    public let id: String
    /// The obligation class.
    public let obligation: ExperimentObligation
    /// Whether the check passed.
    public let passed: Bool

    /// Creates one check result.
    public init(id: String, obligation: ExperimentObligation, passed: Bool) {
        self.id = id
        self.obligation = obligation
        self.passed = passed
    }
}

/// The assertion score for one run.
public struct ExperimentScore: Codable, Sendable, Equatable {
    /// The per-check results.
    public let results: [ExperimentCheckResult]

    /// Creates a score.
    public init(results: [ExperimentCheckResult]) {
        self.results = results
    }

    /// Recall per obligation class, in `0...1`.
    public var recallByObligation: [ExperimentObligation: Double] {
        var passed: [ExperimentObligation: Int] = [:]
        var total: [ExperimentObligation: Int] = [:]
        for result in results {
            total[result.obligation, default: 0] += 1
            if result.passed { passed[result.obligation, default: 0] += 1 }
        }
        return total.reduce(into: [:]) { partial, entry in
            partial[entry.key] = Double(passed[entry.key] ?? 0) / Double(entry.value)
        }
    }

    /// Overall recall, or nil when there are no checks.
    public var overallRecall: Double? {
        guard !results.isEmpty else { return nil }
        return Double(results.filter(\.passed).count) / Double(results.count)
    }

    /// The number of checks that passed.
    public var passed: Int { results.filter(\.passed).count }
    /// The total number of checks.
    public var total: Int { results.count }
}

/// A scoring rule the kit can run.
public protocol ExperimentScenarioScoring: Sendable {
    /// The rule text recorded in a round artifact.
    var rule: String { get }
    /// Scores one run's answer against a case's checks.
    func score(answer: String, checks: [ExperimentScenarioCheck]) -> ExperimentScore
}

/// Deterministic assertion scoring: no similarity or distance metric exists.
public struct ExperimentAssertionScorer: ExperimentScenarioScoring {
    public let rule = "One assertion per obligation; a run's score is the checks it passes. No similarity metric is used."

    /// Creates the assertion scorer.
    public init() {}

    public func score(answer: String, checks: [ExperimentScenarioCheck]) -> ExperimentScore {
        ExperimentScore(results: checks.map { check in
            ExperimentCheckResult(
                id: check.id,
                obligation: check.obligation,
                passed: check.assertion.holds(for: answer)
            )
        })
    }
}

/// A blind rating sheet: every completed run, keyed by an opaque ID, with the
/// arm withheld so the evaluator cannot favour one.
public struct ExperimentBlindRatingSheet: Codable, Sendable, Equatable {
    /// One sheet item.
    public struct Item: Codable, Sendable, Equatable {
        /// The opaque item ID.
        public let id: String
        /// The case prompt.
        public let question: String
        /// The case reference answer.
        public let referenceAnswer: String
        /// The case's listed evidence files.
        public let listedEvidenceFiles: [String]
        /// The run's answer.
        public let answer: String
        /// The run's cited evidence.
        public let citedEvidence: [String]

        /// Creates one item.
        public init(
            id: String,
            question: String,
            referenceAnswer: String,
            listedEvidenceFiles: [String],
            answer: String,
            citedEvidence: [String]
        ) {
            self.id = id
            self.question = question
            self.referenceAnswer = referenceAnswer
            self.listedEvidenceFiles = listedEvidenceFiles
            self.answer = answer
            self.citedEvidence = citedEvidence
        }
    }

    /// The evaluator instructions.
    public let instructions: String
    /// The items.
    public let items: [Item]

    /// Creates one sheet.
    public init(instructions: String, items: [Item]) {
        self.instructions = instructions
        self.items = items
    }
}

/// Blind 0–10 LLM rating, generalizing the RLM scenario's evaluator.
public enum ExperimentBlindRating {
    /// The scoring rule text.
    public static let rule = "One score from 0 to 10 per completed run, assigned after collection by an LLM evaluator that sees the question, the reference answer, the run's answer, and its cited evidence, but not the arm."

    /// The accepted score range.
    public static let range = 0...10

    /// The evaluator instructions.
    public static let instructions = """
    You are scoring answers to questions about the Gnostic repository. For each item, compare `answer` with `referenceAnswer` and give one integer score from 0 to 10: 10 means it carries every point of the reference answer with nothing wrong, 0 means it is wrong or empty. Deduct for claims the reference does not support and for evidence that does not back the answer. Items are independent and in no meaningful order. Reply with only a JSON object mapping each item `id` to its score, for example {"a1b2c3d4e5f6": 7}.
    """

    /// A stable opaque ID for one run of one round. It hides the arm but can be
    /// recomputed from the artifact to apply scores.
    public static func blindID(for record: ExperimentRunRecord, manifest: ExperimentRunManifest) -> String {
        String(
            ExperimentDigest.sha256Hex(
                "\(manifest.gitCommit)|\(manifest.segment)|\(record.caseID)|\(record.arm)|\(record.repetition)"
            ).prefix(12)
        )
    }

    /// Builds the blind sheet for a round artifact.
    public static func sheet(
        for artifact: ExperimentRunArtifact,
        cases: [ExperimentScenarioCase]
    ) -> ExperimentBlindRatingSheet {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        let items = artifact.runs.compactMap { run -> ExperimentBlindRatingSheet.Item? in
            guard run.outcome == "completed", let answer = run.answer, let scenario = byID[run.caseID] else { return nil }
            return ExperimentBlindRatingSheet.Item(
                id: blindID(for: run, manifest: artifact.manifest),
                question: scenario.prompt,
                referenceAnswer: scenario.reference,
                listedEvidenceFiles: scenario.evidencePaths,
                answer: answer,
                citedEvidence: run.evidence.map { "\($0.path):\($0.startLine)-\($0.endLine)" }
            )
        }
        return ExperimentBlindRatingSheet(
            instructions: instructions,
            items: items.sorted { $0.id < $1.id }
        )
    }

    /// Writes each score onto its run. Unknown IDs and out-of-range scores are
    /// refused, so a mangled evaluator reply cannot be half-applied.
    public static func apply(_ scores: [String: Int], to artifact: ExperimentRunArtifact) throws -> ExperimentRunArtifact {
        var updated = artifact
        let indices = Dictionary(uniqueKeysWithValues: artifact.runs.enumerated().map {
            (blindID(for: $0.element, manifest: artifact.manifest), $0.offset)
        })
        for (id, score) in scores {
            guard let index = indices[id], artifact.runs[index].outcome == "completed" else {
                throw ExperimentError.unknownRating(id)
            }
            guard range.contains(score) else {
                throw ExperimentError.ratingOutOfRange(id: id, score: score)
            }
        }
        for (id, score) in scores {
            if let index = indices[id] { updated.runs[index].score = score }
        }
        return updated
    }
}
