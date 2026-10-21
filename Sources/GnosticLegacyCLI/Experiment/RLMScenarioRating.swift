// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticKit

extension ExperimentCommand {
    /// `gnostic experiment rlm-scenario-rating` — blind LLM scoring, offline.
    ///
    /// The kit owns the blind sheet and the score application
    /// (`ExperimentBlindRating`); this command is the RLM scenario's consumer:
    /// it reads the frozen question set for the reference answers and applies
    /// one 0–10 score per completed run.
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
            guard let loaded = try ExperimentArtifactFile.read(artifactURL) else {
                throw RLMScenarioError.invalidArguments("no artifact at \(artifact)")
            }
            if let writeSheet {
                let (questions, _) = try RLMScenarioQuestionSet.load(repositoryRoot: root)
                let sheet = ExperimentBlindRating.sheet(for: loaded, cases: questions)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(sheet).write(to: URL(fileURLWithPath: writeSheet), options: .atomic)
                print("Wrote \(sheet.items.count) blind items to \(writeSheet). Give the file to the evaluator, then run --apply-scores with its JSON reply.")
            } else if let applyScores {
                let scores = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: URL(fileURLWithPath: applyScores)))
                do {
                    let updated = try ExperimentBlindRating.apply(scores, to: loaded)
                    try ExperimentArtifactFile.write(updated, to: artifactURL)
                    let scored = updated.runs.compactMap(\.score)
                    let unscored = updated.runs.filter { $0.outcome == "completed" && $0.score == nil }.count
                    print("Applied \(scores.count) scores; \(scored.count) runs scored, \(unscored) completed runs still unscored.")
                    for arm in updated.manifest.arms {
                        let values = updated.runs.filter { $0.arm == arm }.compactMap(\.score)
                        guard !values.isEmpty else { continue }
                        print(String(format: "  %@: mean %.1f / 10 over %d runs", arm, Double(values.reduce(0, +)) / Double(values.count), values.count))
                    }
                } catch let error as ExperimentError {
                    throw RLMScenarioError.invalidArguments(error.description)
                }
            }
        }
    }
}
