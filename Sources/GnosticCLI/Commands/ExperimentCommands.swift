// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// Structured failures for the generic experiment commands.
enum ExperimentCommandError: Error, Equatable, CustomStringConvertible {
    case unknownScenario(module: String, scenario: String, known: [String])
    case regimeRequired(String)
    case invalidArguments(String)

    var description: String {
        switch self {
        case let .unknownScenario(module, scenario, known):
            "no runnable scenario '\(scenario)' for module '\(module)'. Known scenarios: \(known.isEmpty ? "none" : known.joined(separator: ", "))."
        case let .regimeRequired(scenario):
            "scenario '\(scenario)' needs --regime naming the Ascendant whose provider and models it uses."
        case let .invalidArguments(reason):
            reason
        }
    }
}

/// `gnostic experiment` — opt-in evidence runs that are not part of a Node.
///
/// Provider-backed experiments require PositronicKit, which the clean host may
/// not execute. The command surface remains discoverable; a live run directs the
/// operator to the standalone ACP Runtime process boundary.
struct ExperimentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experiment",
        abstract: "Run opt-in evidence experiments.",
        subcommands: [RLMScenario.self, Replay.self, RLMScenarioRating.self]
    )

    /// `gnostic experiment rlm-scenario` — the RLM live stages.
    struct RLMScenario: AsyncParsableCommand {
        static let commandName = "rlm-scenario"

        static let configuration = CommandConfiguration(
            commandName: commandName,
            abstract: "Run the RLM scenario live stages (pilot or full matrix) against a configured provider.",
            discussion: """
            Without --confirm-spend this prints the plan and a worst-case cost ceiling. \
            The live provider path runs behind the standalone ACP Runtime process boundary.
            """
        )

        @Option(name: .long, help: "Stage to run: pilot (Stage 2) or matrix (Stage 3).")
        var stage: String

        @Option(name: .long, help: "UUID of the Ascendant whose provider, models, and key are used.")
        var ascendant: String

        @OptionGroup var configOptions: ConfigPathOptions

        @Option(name: .long, help: "Repository root holding the corpus and the frozen question set.")
        var repository: String = "."

        @Option(name: .long, help: "Pilot question ID (pilot only).")
        var question: String = "Q1"

        @Option(name: .long, parsing: .upToNextOption, help: "Matrix question IDs (matrix only; default all 12).")
        var questions: [String] = []

        @Option(name: .long, help: "Repetitions per question and executor (1–3).")
        var repetitions: Int = 1

        @Option(name: .long, parsing: .upToNextOption, help: "Executors to compare: guile and/or chibi.")
        var executor: [String] = ["guile", "chibi"]

        @Option(name: .long, help: "Provider input price, USD per million tokens. Omit all prices for a flat-rate subscription.")
        var inputPrice: Double?

        @Option(name: .long, help: "Provider output price, USD per million tokens.")
        var outputPrice: Double?

        @Option(name: .long, help: "Date the prices were in effect (YYYY-MM-DD).")
        var pricesDate: String?

        @Option(name: .long, help: "Artifact path (defaults to the stage's Documentation/Experiments file).")
        var output: String?

        @Option(name: .long, help: "Completed pilot artifact that authorises the matrix.")
        var pilot: String?

        @Option(name: .long, help: "Stop before a run that could take total spend past this many USD (priced rounds only).")
        var maxCost: Double?

        @Flag(name: .long, help: "Contact the provider. A priced round also requires --max-cost.")
        var confirmSpend = false

        @Flag(name: .long, help: "Allow a run outside the pinned image (recorded as unpinned).")
        var allowUnpinnedHost = false

        func run() async throws {
            throw RLMScenarioError.configuration(
                "live RLM experiments run behind the standalone ACP Runtime process boundary; the clean host does not execute PositronicKit"
            )
        }
    }
}
