// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import GnosticHost
import GnosticKit
import GnosticPositronicContext
import GnosticRLM
import PKContracts
import PositronicKit

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
            "scenario '\(scenario)' needs --regime naming the Positronic Ascendant whose provider and models it uses."
        case let .invalidArguments(reason):
            reason
        }
    }
}

/// Resolves a `run <module> <scenario>` pair to a driver.
///
/// The catalog is CLI-owned, like the experiment subcommand dispatch: the CLI
/// owns execution, and a module declares nothing it cannot run. Built-in
/// scripted scenarios run offline; a live scenario names the regime it needs.
enum ExperimentScenarioCatalog {
    /// One catalog entry.
    struct Entry {
        /// Whether the scenario needs `--regime`.
        let requiresRegime: Bool
        /// Builds the driver for a `run` invocation.
        let makeDriver: @Sendable (ExperimentCommand.Run) throws -> any ExperimentScenarioDriver
        /// The number of cases in the full comparison a pilot scales to.
        let matrixCaseCount: Int
    }

    /// The built-in scenarios by module.
    static let builtIn: [String: [String]] = ["kit": ["self-check"], "context": ["baselines", "gate"]]

    /// Resolves one entry.
    static func entry(module: String, scenario: String) throws -> Entry {
        switch (module, scenario) {
        case ("kit", "self-check"):
            Entry(requiresRegime: false, makeDriver: { _ in SelfCheckScenario.driver }, matrixCaseCount: 1)
        case ("context", "baselines"):
            Entry(
                requiresRegime: false,
                makeDriver: { _ in ContextBenchmarkDriver() },
                matrixCaseCount: ContextFixtureTranscript.cases.count
            )
        case ("context", "gate"):
            Entry(
                requiresRegime: false,
                makeDriver: { _ in ContextGateDriver() },
                matrixCaseCount: ContextFixtureTranscript.cases.count
            )
        default:
            throw ExperimentCommandError.unknownScenario(
                module: module,
                scenario: scenario,
                known: builtIn[module] ?? []
            )
        }
    }
}

/// The kit's built-in deterministic self-check scenario.
///
/// It proves the generic run path end to end with no provider: a fixed answer is
/// scored by assertions, so `make verify` exercises the command's mechanics.
enum SelfCheckScenario {
    static let driver = ScriptedScenarioDriver(
        cases: [
            ExperimentScenarioCase(
                id: "self-check",
                prompt: "Confirm the experiment kit is wired.",
                reference: "The kit runs offline and scores with assertions.",
                evidencePaths: ["Sources/GnosticKit"]
            )
        ],
        arms: ["scripted"],
        scripts: [
            "self-check": .init(
                answer: "The experiment kit runs offline and scores with assertions, port 8317.",
                checks: [
                    .init(id: "fact", obligation: .fact, description: "names the kit", assertion: .containsNormalized("experiment kit")),
                    .init(id: "offline", obligation: .negativeConstraint, description: "no provider", assertion: .absent("provider")),
                    .init(id: "port", obligation: .exactValue, description: "exact value", assertion: .contains("8317")),
                ]
            )
        ]
    )
}

extension ExperimentCommand {
    /// `gnostic experiment run <module> <scenario> --regime …`.
    ///
    /// Without `--confirm-spend` it contacts no provider. A priced round also
    /// requires a positive `--max-cost`.
    struct Run: AsyncParsableCommand {
        static let commandName = "run"

        static let configuration = CommandConfiguration(
            commandName: commandName,
            abstract: "Run a scenario under a regime and record the result.",
            discussion: """
            A built-in scenario runs offline. A live scenario resolves its provider \
            and models from the Ascendant named by --regime in the node manifest.
            """
        )

        @Argument(help: "The module that owns the scenario.")
        var module: String

        @Argument(help: "The scenario to run.")
        var scenario: String

        @Option(name: .long, help: "UUID of the Positronic Ascendant whose provider, models, and key are used.")
        var regime: String?

        @Option(name: .customLong("config"), help: "Path to the node manifest.")
        var configPath: String?

        @Option(name: .long, help: "Repository root holding the scenario cases and corpus.")
        var repository: String = "."

        @Option(name: .long, help: "Artifact path.")
        var output: String?

        @Option(name: .long, help: "Provider input price, USD per million tokens.")
        var inputPrice: Double?

        @Option(name: .long, help: "Provider output price, USD per million tokens.")
        var outputPrice: Double?

        @Option(name: .long, help: "Date the prices were in effect (YYYY-MM-DD).")
        var pricesDate: String?

        @Option(name: .long, help: "Stop before a run that could take total spend past this many USD.")
        var maxCost: Double?

        @Flag(name: .long, help: "Contact a provider. A priced round also requires --max-cost.")
        var confirmSpend = false

        @Flag(name: .long, help: "Allow a run outside the pinned image (recorded as unpinned).")
        var allowUnpinnedHost = false

        func run() async throws {
            let pricing = try Self.pricing(inputPrice: inputPrice, outputPrice: outputPrice, pricesDate: pricesDate)
            if confirmSpend, pricing != nil, (maxCost ?? 0) <= 0 {
                throw ExperimentCommandError.invalidArguments("--confirm-spend on a priced round requires a positive --max-cost")
            }
            let entry = try ExperimentScenarioCatalog.entry(module: module, scenario: scenario)
            if entry.requiresRegime, regime == nil {
                throw ExperimentCommandError.regimeRequired(scenario)
            }

            let root = URL(fileURLWithPath: repository).standardizedFileURL
            let driver = try entry.makeDriver(self)
            let imageDigest = ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_IMAGE_DIGEST"].flatMap { $0.isEmpty ? nil : $0 }
            let manifest = ExperimentRunManifest(
                manifestID: "\(module)-\(scenario)-manifest-v1",
                manifestVersion: "v1",
                segment: "run",
                regime: Self.regime(module: module, scenario: scenario),
                gitCommit: ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_COMMIT"] ?? RLMScenarioGit(root: root).head(),
                workingTreeClean: RLMScenarioGit(root: root).isClean(),
                imageDigest: imageDigest,
                host: "\(RLMScenarioHost.operatingSystem)/\(RLMScenarioHost.architecture)",
                samplingParameters: "defaults",
                budget: ExperimentBudget(wallDurationSeconds: 0, modelCalls: 0, estimatedModelTokens: 0),
                caseSetSHA256: ExperimentDigest.sha256Hex(driver.cases.map(\.id).joined(separator: ",")),
                corpusRevisionDigest: nil,
                caseIDs: driver.cases.map(\.id),
                arms: driver.arms,
                repetitions: 1,
                pricing: pricing
            )
            let outputPath = output ?? "Documentation/Experiments/\(module)-\(scenario)-run.json"
            let outputURL = URL(fileURLWithPath: outputPath, relativeTo: root)
            let existing = try ExperimentArtifactFile.read(outputURL)
            let plan = ExperimentPlan(manifest: manifest, matrixCaseCount: entry.matrixCaseCount)
            let ceiling = plan.ceiling
            print("Experiment \(module) \(scenario): \(plan.runKeys.count) run(s), ceiling ≤ \(ceiling.maximumModelCalls) calls"
                + (ceiling.maximumEstimatedCostUSD.map { String(format: ", ≈ $%.2f", $0) } ?? " (unpriced)"))
            try await preflight(driver)

            guard confirmSpend else {
                print("Dry run: no provider was contacted. Re-run with --confirm-spend\(pricing != nil ? " --max-cost <USD>" : "") to run.")
                return
            }
            let runner = ExperimentRunner(
                plan: plan,
                maximumCostUSD: maxCost,
                scoringRule: ExperimentAssertionScorer().rule,
                execute: { key in
                    let scenario = driver.cases.first { $0.id == key.caseID }!
                    return await driver.run(scenario, key: key)
                },
                persist: { try ExperimentArtifactFile.write($0, to: outputURL) },
                report: { print($0) }
            )
            let artifact = try await runner.run(resuming: existing)
            print("Status: \(artifact.status). \(artifact.runs.filter { $0.outcome == "completed" }.count) of \(artifact.runs.count) runs completed.")
            print("Artifact: \(outputPath)")
        }

        private func preflight(_ driver: any ExperimentScenarioDriver) async throws {
            // A deterministic check that the scenario can produce a record before
            // any spend: execute the first run with no persistence.
            guard let first = driver.cases.first, let arm = driver.arms.first else { return }
            _ = await driver.run(first, key: ExperimentRunKey(caseID: first.id, arm: arm, repetition: 1))
        }

        private static func pricing(inputPrice: Double?, outputPrice: Double?, pricesDate: String?) throws -> ExperimentPricing? {
            switch (inputPrice, outputPrice, pricesDate) {
            case (nil, nil, nil):
                return nil
            case let (input?, output?, date?):
                guard input >= 0, output >= 0 else {
                    throw ExperimentCommandError.invalidArguments("prices must not be negative")
                }
                return ExperimentPricing(inputUSDPerMillionTokens: input, outputUSDPerMillionTokens: output, ratesDate: date)
            default:
                throw ExperimentCommandError.invalidArguments("pass all of --input-price, --output-price, and --prices-date, or none")
            }
        }

        private static func regime(module: String, scenario: String) -> ExperimentRegime {
            ExperimentRegime(
                backendKind: "kit",
                modules: [module],
                modelTiers: [:],
                policies: ["scenario": scenario]
            )
        }
    }
}

extension ExperimentCommand {
    /// `gnostic experiment context-gate`.
    ///
    /// Runs the offline hypothesis gate and writes the machine-readable numbers
    /// and the Markdown decision record. No provider is contacted.
    struct ContextGateCommand: AsyncParsableCommand {
        static let commandName = "context-gate"

        static let configuration = CommandConfiguration(
            commandName: commandName,
            abstract: "Run the offline context hypothesis gate and record the decision.",
            discussion: """
            Scores five strategies on the shared planted obligations with deterministic \
            assertions, then writes Documentation/Experiments/context-gate.json and \
            context-gate.md. Every arm runs through the fixture seam, so no provider is contacted.
            """
        )

        @Option(name: .long, help: "Repository root.")
        var repository: String = "."

        @Option(name: .long, help: "JSON output path.")
        var output: String?

        @Option(name: .long, help: "Markdown output path.")
        var markdown: String?

        func run() async throws {
            let root = URL(fileURLWithPath: repository).standardizedFileURL
            let result = try await ContextGate().run()
            let jsonPath = output ?? "Documentation/Experiments/context-gate.json"
            let markdownPath = markdown ?? "Documentation/Experiments/context-gate.md"
            try result.jsonData().write(to: URL(fileURLWithPath: jsonPath, relativeTo: root))
            try result.markdown().write(
                to: URL(fileURLWithPath: markdownPath, relativeTo: root),
                atomically: true,
                encoding: .utf8
            )
            print(result.summary())
            print("JSON: \(jsonPath)")
            print("Markdown: \(markdownPath)")
        }
    }
}

extension ExperimentCommand {
    /// `gnostic experiment export --artifact <path>`.
    struct Export: ParsableCommand {
        static let commandName = "export"

        static let configuration = CommandConfiguration(
            commandName: commandName,
            abstract: "Print a round artifact as machine-readable JSON."
        )

        @Option(name: .long, help: "Artifact path.")
        var artifact: String

        @Option(name: .long, help: "Repository root.")
        var repository: String = "."

        func run() throws {
            let url = URL(fileURLWithPath: artifact, relativeTo: URL(fileURLWithPath: repository).standardizedFileURL)
            guard let loaded = try ExperimentArtifactFile.read(url) else {
                throw ExperimentCommandError.unknownScenario(module: "artifact", scenario: artifact, known: [])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(loaded), as: UTF8.self))
        }
    }
}
