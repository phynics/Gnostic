// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticRLM

/// A blind rating sheet: every completed run, keyed by an opaque ID, with the
/// executor withheld so the evaluator cannot favour one.
struct RLMScenarioRatingSheet: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        let id: String
        let question: String
        let referenceAnswer: String
        let listedEvidenceFiles: [String]
        let answer: String
        let citedEvidence: [String]
    }

    static let instructions = """
    You are scoring answers to questions about the Gnostic repository. For each item, compare `answer` with `referenceAnswer` and give one integer score from 0 to 10: 10 means it carries every point of the reference answer with nothing wrong, 0 means it is wrong or empty. Deduct for claims the reference does not support and for evidence that does not back the answer. Items are independent and in no meaningful order. Reply with only a JSON object mapping each item `id` to its score, for example {"a1b2c3d4e5f6": 7}.
    """

    let instructions: String
    let items: [Item]
}

enum RLMScenarioBlindRating {
    /// A stable opaque ID for one run of one round. It hides the executor but
    /// can be recomputed from the artifact to apply scores.
    static func blindID(for run: RLMScenarioRunRecord, round: RLMScenarioRoundIdentity) -> String {
        String(RLMDigest.sha256Hex("\(round.gitCommit)|\(round.stage.rawValue)|\(run.questionID)|\(run.executor)|\(run.repetition)").prefix(12))
    }

    static func sheet(for artifact: RLMScenarioLiveArtifact, questions: [RLMScenarioQuestion]) -> RLMScenarioRatingSheet {
        let byID = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
        let items = artifact.runs.compactMap { run -> RLMScenarioRatingSheet.Item? in
            guard run.outcome == "completed", let answer = run.answer, let question = byID[run.questionID] else { return nil }
            return RLMScenarioRatingSheet.Item(
                id: blindID(for: run, round: artifact.round),
                question: question.question,
                referenceAnswer: question.referenceAnswer,
                listedEvidenceFiles: question.evidencePaths,
                answer: answer,
                citedEvidence: run.evidence.map { "\($0.path):\($0.startLine)-\($0.endLine)" }
            )
        }
        // Ordered by the opaque ID, so neither executor nor repetition order shows.
        return RLMScenarioRatingSheet(instructions: RLMScenarioRatingSheet.instructions, items: items.sorted { $0.id < $1.id })
    }

    /// Writes each score onto its run. Unknown IDs and out-of-range scores are
    /// refused, so a mangled evaluator reply cannot be half-applied.
    static func apply(_ scores: [String: Int], to artifact: RLMScenarioLiveArtifact) throws -> RLMScenarioLiveArtifact {
        var updated = artifact
        let indices = Dictionary(uniqueKeysWithValues: artifact.runs.enumerated().map {
            (blindID(for: $0.element, round: artifact.round), $0.offset)
        })
        for (id, score) in scores {
            guard let index = indices[id], artifact.runs[index].outcome == "completed" else {
                throw RLMScenarioError.invalidArguments("score for unknown or incomplete run \(id)")
            }
            guard RLMScenarioScoring.range.contains(score) else {
                throw RLMScenarioError.invalidArguments("score \(score) for \(id) is outside 0–10")
            }
        }
        for (id, score) in scores {
            if let index = indices[id] { updated.runs[index].score = score }
        }
        return updated
    }
}

extension ExperimentCommand {
    /// `gnostic experiment rlm-scenario-rating` — blind LLM scoring, offline.
    struct RLMScenarioRating: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rlm-scenario-rating",
            abstract: "Export a blind rating sheet from a scenario artifact, or apply an evaluator's 0–10 scores to it."
        )

        @Option(name: .long, help: "Scenario artifact (a Stage 2 or Stage 3 JSON file).")
        var artifact: String

        @Option(name: .long, help: "Repository root holding the frozen question set.")
        var repository: String = "."

        @Option(name: .long, help: "Write the blind rating sheet here, for the evaluator LLM.")
        var writeSheet: String?

        @Option(name: .long, help: "Apply the evaluator's reply: a JSON object of sheet ID to score.")
        var applyScores: String?

        func run() throws {
            guard (writeSheet == nil) != (applyScores == nil) else {
                throw RLMScenarioError.invalidArguments("pass exactly one of --write-sheet or --apply-scores")
            }
            let root = URL(fileURLWithPath: repository).standardizedFileURL
            let artifactURL = URL(fileURLWithPath: artifact, relativeTo: root)
            guard let loaded = try RLMScenarioArtifactFile.read(artifactURL) else {
                throw RLMScenarioError.invalidArguments("no artifact at \(artifact)")
            }
            if let writeSheet {
                let (questions, _) = try RLMScenarioQuestionSet.load(repositoryRoot: root)
                let sheet = RLMScenarioBlindRating.sheet(for: loaded, questions: questions)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(sheet).write(to: URL(fileURLWithPath: writeSheet), options: .atomic)
                print("Wrote \(sheet.items.count) blind items to \(writeSheet). Give the file to the evaluator, then run --apply-scores with its JSON reply.")
            } else if let applyScores {
                let scores = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: URL(fileURLWithPath: applyScores)))
                let updated = try RLMScenarioBlindRating.apply(scores, to: loaded)
                try RLMScenarioArtifactFile.write(updated, to: artifactURL)
                let scored = updated.runs.compactMap(\.score)
                let unscored = updated.runs.filter { $0.outcome == "completed" && $0.score == nil }.count
                print("Applied \(scores.count) scores; \(scored.count) runs scored, \(unscored) completed runs still unscored.")
                for executor in updated.round.executors {
                    let values = updated.runs.filter { $0.executor == executor }.compactMap(\.score)
                    guard !values.isEmpty else { continue }
                    print(String(format: "  %@: mean %.1f / 10 over %d runs", executor, Double(values.reduce(0, +)) / Double(values.count), values.count))
                }
            }
        }
    }
}
