// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import GnosticHost
import GnosticKit
import GnosticRLM
import PKContracts
import PositronicKit

/// `gnostic experiment` — opt-in evidence runs that are not part of a Node.
///
/// The subcommand surface comes from the composition root: module descriptors
/// declare optional experiment subcommands, and this command registers the
/// implementation it owns for each declared name. The CLI owns argument
/// parsing and rendering; `GnosticHost` never depends on `ArgumentParser`.
struct ExperimentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experiment",
        abstract: "Run opt-in evidence experiments.",
        subcommands: experimentSubcommands()
    )

    /// The CLI's implementations for module experiment subcommands, keyed by
    /// the command name a module descriptor declares.
    ///
    /// The mapping is by name so one declaration both routes and documents the
    /// command: `BackendComposition` decides which names are live from the
    /// registered modules, and this table binds a live name to the parser that
    /// owns it.
    private static let moduleSubcommandImplementations: [String: ParsableCommand.Type] = [
        RLMScenario.commandName: RLMScenario.self,
    ]

    /// Every experiment subcommand this CLI exposes.
    ///
    /// The rating command is intrinsic to the CLI. Module experiment
    /// subcommands come from the composed module descriptors, so a module
    /// that stops declaring its subcommand also stops being advertised and
    /// routed here.
    private static func experimentSubcommands() -> [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = []
        for declared in BackendComposition.default.registeredExperimentSubcommands {
            if let implementation = moduleSubcommandImplementations[declared.name] {
                commands.append(implementation)
            }
        }
        commands.append(Run.self)
        commands.append(Export.self)
        commands.append(Replay.self)
        commands.append(ContextGateCommand.self)
        commands.append(RLMScenarioRating.self)
        return commands
    }

    /// `gnostic experiment rlm-scenario` — the #354 live stages (manifest §8).
    ///
    /// The kit owns the mundane round machinery (`ExperimentRunner`,
    /// `ExperimentArtifactFile`, metering, scoring, and spend guard). This
    /// command carries only RLM-specific glue: the corpus snapshot, the worker
    /// preflight, the pinned-image gate, and the RLM run record mapping.
    struct RLMScenario: AsyncParsableCommand {
        /// The routing key a module descriptor must declare to expose this command.
        static let commandName = "rlm-scenario"

        static let configuration = CommandConfiguration(
            commandName: commandName,
            abstract: "Run the RLM scenario live stages (pilot or full matrix) against a configured provider.",
            discussion: """
            Without --confirm-spend this prints the plan and a worst-case cost ceiling, \
            checks that each executor starts, and never contacts the provider. \
            The artifact is rewritten after every run; re-running the same command resumes it.
            """
        )

        @Option(name: .long, help: "Stage to run: pilot (Stage 2) or matrix (Stage 3).")
        var stage: String

        @Option(name: .long, help: "UUID of the Positronic Ascendant whose provider, models, and key are used.")
        var ascendant: String

        @Option(name: .customLong("config"), help: "Path to the node manifest.")
        var configPath: String?

        @Option(name: .long, help: "Repository root holding the corpus and the frozen question set.")
        var repository: String = "."

        @Option(name: .long, help: "Pilot question ID (pilot only).")
        var question: String = "Q1"

        @Option(name: .long, parsing: .upToNextOption, help: "Matrix question IDs (matrix only; default all 12).")
        var questions: [String] = []

        @Option(name: .long, help: "Repetitions per question and executor (1–3).")
        var repetitions: Int = RLMScenarioStage.defaultRepetitions

        @Option(name: .long, parsing: .upToNextOption, help: "Executors to compare: guile and/or chibi.")
        var executor: [String] = RLMWorkerSelection.allCases.map(\.rawValue)

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
            let priced = inputPrice != nil
            if confirmSpend, priced, (maxCost ?? 0) <= 0 {
                throw RLMScenarioError.invalidArguments("--confirm-spend on a priced round requires a positive --max-cost")
            }
            if !priced, maxCost != nil {
                throw RLMScenarioError.invalidArguments("--max-cost needs --input-price, --output-price, and --prices-date")
            }
            let root = URL(fileURLWithPath: repository).standardizedFileURL
            let preparation = try await RLMScenarioPreparation.prepare(command: self, root: root)
            let plan = preparation.plan
            let outputPath = output ?? preparation.stage.defaultArtifactPath
            let outputURL = URL(fileURLWithPath: outputPath, relativeTo: root)
            let existing = try ExperimentArtifactFile.read(outputURL)
            if let existing {
                let differences = plan.manifest.differences(from: existing.manifest)
                guard differences.isEmpty else {
                    throw RLMScenarioError.roundMismatch("\(outputPath) differs in \(differences.joined(separator: ", "))")
                }
            }

            print(RLMScenarioPlanRenderer.render(plan: plan, existing: existing, outputPath: outputPath))
            try await preparation.preflight()
            print("Preflight: every selected executor started and shut down cleanly.")

            guard confirmSpend else {
                print("Dry run: no provider was contacted. Re-run with --confirm-spend\(priced ? " --max-cost <USD>" : "") to run.")
                return
            }

            let runner = ExperimentRunner(
                plan: plan,
                maximumCostUSD: maxCost,
                scoringRule: ExperimentBlindRating.rule,
                measurements: RLMScenarioMeasurements.unavailable,
                execute: preparation.execute,
                persist: { try ExperimentArtifactFile.write($0, to: outputURL) },
                report: { print($0) }
            )
            let artifact = try await runner.run(resuming: existing)
            print(RLMScenarioPlanRenderer.summary(artifact))
        }
    }
}

/// Manifest §8 live stages.
enum RLMScenarioStage: String, Sendable, CaseIterable {
    /// Stage 2: one question, both executors.
    case pilot
    /// Stage 3: the chosen questions (all 12 by default), both executors.
    case matrix

    /// Manifest v7: the owner accepted a light sample, one repetition by default.
    static let defaultRepetitions = 1
    static let maximumRepetitions = 3

    var defaultArtifactPath: String {
        switch self {
        case .pilot: "Documentation/Experiments/rlm-scenario-stage2.json"
        case .matrix: "Documentation/Experiments/rlm-scenario-stage3.json"
        }
    }
}

/// The RLM scenario's unavailable measurements, recorded in every artifact.
enum RLMScenarioMeasurements {
    static let unavailable = [
        ExperimentMeasurementStatus(id: "M7", status: "requires-rater", reason: "Each completed run's score is set after collection by the blind LLM evaluator (v7 §5)."),
        ExperimentMeasurementStatus(id: "M8", status: "unavailable", reason: "Arm D (ordinary Positronic Workspace analysis) has no headless runner, so M8 is not required (§2)."),
    ]
}

/// Resolves the round's fixed parameters and builds the production run path.
struct RLMScenarioPreparation: Sendable {
    let stage: RLMScenarioStage
    let plan: ExperimentPlan
    let preflight: @Sendable () async throws -> Void
    let execute: ExperimentRunner.Execute

    static let budget = RLMRunBudget.standard

    static func prepare(command: ExperimentCommand.RLMScenario, root: URL) async throws -> Self {
        guard let stage = RLMScenarioStage(rawValue: command.stage) else {
            throw RLMScenarioError.invalidArguments("--stage must be pilot or matrix")
        }
        let executors = try command.executor.map { name -> RLMWorkerSelection in
            guard let selection = RLMWorkerSelection(rawValue: name.lowercased()) else {
                throw RLMScenarioError.invalidArguments("--executor must be guile or chibi")
            }
            return selection
        }
        guard (1...RLMScenarioStage.maximumRepetitions).contains(command.repetitions) else {
            throw RLMScenarioError.invalidArguments("--repetitions must be between 1 and \(RLMScenarioStage.maximumRepetitions)")
        }
        guard !executors.isEmpty, Set(executors).count == executors.count else {
            throw RLMScenarioError.invalidArguments("--executor must name distinct executors")
        }
        let pricing: ExperimentPricing?
        switch (command.inputPrice, command.outputPrice, command.pricesDate) {
        case (nil, nil, nil):
            pricing = nil
        case let (input?, output?, date?):
            guard input >= 0, output >= 0 else {
                throw RLMScenarioError.invalidArguments("prices must not be negative")
            }
            pricing = ExperimentPricing(inputUSDPerMillionTokens: input, outputUSDPerMillionTokens: output, ratesDate: date)
        default:
            throw RLMScenarioError.invalidArguments("pass all of --input-price, --output-price, and --prices-date, or none for a flat-rate subscription")
        }

        let (questions, questionSetSHA256) = try RLMScenarioQuestionSet.load(repositoryRoot: root)
        let selected: [ExperimentScenarioCase]
        switch stage {
        case .pilot:
            guard let pilotQuestion = questions.first(where: { $0.id == command.question }) else {
                throw RLMScenarioError.invalidArguments("--question must be one of Q1 through Q12")
            }
            selected = [pilotQuestion]
        case .matrix:
            if command.questions.isEmpty {
                selected = questions
            } else {
                let wanted = Set(command.questions)
                selected = questions.filter { wanted.contains($0.id) }
                guard selected.count == wanted.count else {
                    throw RLMScenarioError.invalidArguments("--questions must name distinct IDs from Q1 through Q12")
                }
            }
        }

        let imageDigest = ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_IMAGE_DIGEST"].flatMap { $0.isEmpty ? nil : $0 }
        guard imageDigest != nil || command.allowUnpinnedHost else {
            throw RLMScenarioError.invalidArguments(
                "no pinned image: run through `make scenario-live`, or pass --allow-unpinned-host to record an unpinned round (manifest §7)"
            )
        }

        let client = try loadClient(ascendant: command.ascendant, configPath: command.configPath)
        let configuration = await client.configuration
        let provider = configuration.activeProviderConfiguration
        let source = RLMScenarioRepositorySource(root: root.path, prefixes: RLMScenarioQuestionSet.corpusPrefixes)
        let policy = RLMCorpusPolicy(allowedPathPrefixes: RLMScenarioQuestionSet.corpusPrefixes)
        let corpus = try await RLMCorpusSnapshotter(policy: policy).capture(
            from: source,
            workspaceID: RLMScenarioRepositorySource.workspaceID,
            budget: budget
        )
        let git = RLMScenarioGit(root: root)

        let manifest = ExperimentRunManifest(
            manifestID: "rlm-scenario-manifest-v1",
            manifestVersion: "v7",
            segment: stage.rawValue,
            regime: ExperimentRegime(
                backendKind: AscendantAdapterRegistry.positronicKind,
                modules: ["rlm"],
                modelTiers: [
                    "primary": provider.modelName,
                    "utility": provider.utilityModel,
                    "fast": provider.fastModel,
                ],
                provider: configuration.activeProvider.rawValue,
                endpoint: provider.endpoint,
                policies: ["scenario": "rlm-scenario"]
            ),
            gitCommit: ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_COMMIT"] ?? git.head(),
            workingTreeClean: git.isClean(),
            imageDigest: imageDigest,
            host: "\(RLMScenarioHost.operatingSystem)/\(RLMScenarioHost.architecture)",
            samplingParameters: "provider defaults (the RLM adapters set no generation parameters)",
            budget: budgetDescription(budget),
            caseSetSHA256: questionSetSHA256,
            corpusRevisionDigest: corpus.revisionDigest,
            caseIDs: selected.map(\.id),
            arms: executors.map(\.rawValue),
            repetitions: command.repetitions,
            pricing: pricing
        )

        var pilot: ExperimentPilotReference?
        if stage == .matrix {
            guard let pilotPath = command.pilot else {
                throw RLMScenarioError.pilotRequired("pass --pilot with the completed Stage 2 artifact")
            }
            pilot = try ExperimentArtifactFile.authorisingPilot(
                at: URL(fileURLWithPath: pilotPath, relativeTo: root),
                displayPath: pilotPath,
                for: manifest
            )
        }

        let transport = LLMStreamClientExperimentTransport(client: client)
        return Self(
            stage: stage,
            plan: ExperimentPlan(manifest: manifest, matrixCaseCount: questions.count, pilot: pilot),
            preflight: { try await preflightExecutors(executors, policy: policy) },
            execute: { key in
                guard let question = selected.first(where: { $0.id == key.caseID }) else {
                    return ExperimentRunRecord(
                        caseID: key.caseID,
                        arm: key.arm,
                        repetition: key.repetition,
                        startedAtUTC: ISO8601DateFormatter().string(from: Date()),
                        outcome: "failed",
                        failureCategory: "unknown-case",
                        failure: "no selected case for \(key.caseID)",
                        answer: nil,
                        evidence: [],
                        sourceRevisionDigest: nil,
                        wallMilliseconds: 0,
                        metrics: ExperimentRunMetrics(),
                        rootUsage: ExperimentUsage(),
                        leafUsage: ExperimentUsage(),
                        costUSD: 0,
                        costComplete: true
                    )
                }
                return await executeRun(
                    question: question,
                    key: key,
                    transport: transport,
                    pricing: pricing,
                    policy: policy,
                    source: source,
                    corpusRevision: corpus.revisionDigest
                )
            }
        )
    }

    /// Maps the RLM host budget onto the kit budget the runner and ceiling use.
    static func budgetDescription(_ budget: RLMRunBudget) -> ExperimentBudget {
        ExperimentBudget(
            wallDurationSeconds: budget.maxWallDuration.components.seconds,
            modelCalls: budget.maxRootIterations + budget.maxLeafModelCalls,
            estimatedModelTokens: budget.maxEstimatedModelTokens,
            additional: [
                "rootIterations": budget.maxRootIterations,
                "leafModelCalls": budget.maxLeafModelCalls,
                "cellRepairs": budget.maxCellRepairs,
                "corpusBytesRead": budget.maxCorpusBytesRead,
                "evidenceReferences": budget.maxEvidenceReferences,
            ]
        )
    }

    private static func loadClient(ascendant: String, configPath: String?) throws -> any LLMStreamClient {
        guard let id = UUID(uuidString: ascendant) else {
            throw RLMScenarioError.invalidArguments("--ascendant must be a UUID")
        }
        let store = CLIConfigurationStore(configPath: configPath.map { URL(fileURLWithPath: $0) })
        let manifest = try store.loadManifest()
        guard let entry = manifest.ascendants.first(where: { $0.id == id }) else {
            throw RLMScenarioError.configuration("no Ascendant \(ascendant) in \(store.path().path)")
        }
        guard entry.backend.kind == AscendantAdapterRegistry.positronicKind else {
            throw RLMScenarioError.configuration("Ascendant \(ascendant) is not a Positronic Ascendant")
        }
        let backend = PositronicBackendConfiguration(backend: entry.backend)
        guard backend.provider != nil else {
            throw RLMScenarioError.configuration("Ascendant \(ascendant) has no provider configured")
        }
        let client = ConfiguredLLMService.make(from: backend)
        guard !(client is UnconfiguredLLMService) else {
            throw RLMScenarioError.configuration("Ascendant \(ascendant)'s provider configuration is incomplete (check the API key)")
        }
        return client
    }

    /// Starts and stops each worker with no model attached, so a missing
    /// interpreter fails before any spend instead of as a recorded run.
    private static func preflightExecutors(_ executors: [RLMWorkerSelection], policy: RLMCorpusPolicy) async throws {
        let unused = ExperimentMeteredModel(transport: RLMScenarioRefusingTransport())
        let unusedService = PositronicContributionModelServiceAdapter(service: unused)
        for executor in executors {
            do {
                let assembly = try RLMRunAssemblyFactory.make(
                    model: unusedService,
                    worker: executor,
                    budget: budget,
                    policy: policy,
                    progressSink: nil
                )
                try await assembly.evaluator.start()
                await assembly.evaluator.shutdown()
            } catch {
                throw RLMScenarioError.configuration("preflight: the \(executor.rawValue) executor cannot start on this host (\(error)); no provider was contacted")
            }
        }
    }

    private static func executeRun(
        question: ExperimentScenarioCase,
        key: ExperimentRunKey,
        transport: any ExperimentModelTransport,
        pricing: ExperimentPricing?,
        policy: RLMCorpusPolicy,
        source: RLMScenarioRepositorySource,
        corpusRevision: String
    ) async -> ExperimentRunRecord {
        let rootModel = ExperimentMeteredModel(transport: transport)
        let leafModel = ExperimentMeteredModel(transport: transport)
        let rootService = PositronicContributionModelServiceAdapter(service: rootModel)
        let leafService = PositronicContributionModelServiceAdapter(service: leafModel)
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let clock = ContinuousClock()
        let started = clock.now

        var result: RLMRunResult?
        var setupFailure: String?
        do {
            let assembly = try RLMRunAssemblyFactory.make(
                model: rootService,
                leafService: leafService,
                worker: RLMWorkerSelection(rawValue: key.arm) ?? .guile,
                budget: budget,
                policy: policy,
                progressSink: nil
            )
            try await assembly.evaluator.start()
            result = await assembly.engine.run(
                question: question.prompt,
                workspaceID: RLMScenarioRepositorySource.workspaceID,
                source: source
            )
            await assembly.evaluator.shutdown()
        } catch {
            setupFailure = String(describing: error)
        }
        let elapsed = clock.now - started
        let rootUsage = await rootModel.usage
        let leafUsage = await leafModel.usage
        let usage = rootUsage + leafUsage

        var outcome = "failed"
        var failure = setupFailure
        var answer: String?
        var evidence: [ExperimentEvidence] = []
        switch result?.outcome {
        case let .completed(text, references)?:
            outcome = "completed"
            answer = text
            evidence = references.map {
                ExperimentEvidence(id: $0.chunkID, path: $0.path, startLine: $0.startLine, endLine: $0.endLine)
            }
        case let .failed(runFailure)?:
            failure = runFailure.description
        case .cancelled?:
            outcome = "cancelled"
        case .fenced?:
            outcome = "fenced"
        case nil:
            break
        }
        let revision = result.map { _ in corpusRevision }

        return ExperimentRunRecord(
            caseID: key.caseID,
            arm: key.arm,
            repetition: key.repetition,
            startedAtUTC: startedAt,
            outcome: outcome,
            failureCategory: setupFailure == nil ? nil : "setup",
            failure: failure,
            answer: answer,
            evidence: evidence,
            sourceRevisionDigest: revision,
            wallMilliseconds: Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000,
            metrics: ExperimentRunMetrics(values: metricsValues(result?.metrics ?? .unavailable())),
            rootUsage: rootUsage,
            leafUsage: leafUsage,
            costUSD: pricing?.cost(of: usage) ?? 0,
            costComplete: usage.callsWithoutUsage == 0,
            score: nil
        )
    }

    /// Maps the RLM deterministic counters onto the kit's named metrics.
    private static func metricsValues(_ metrics: RLMRunMetrics) -> [String: Double] {
        [
            "rootIterations": Double(metrics.rootIterations),
            "rootCellRejections": Double(metrics.rootCellRejections),
            "runtimeFailures": Double(metrics.runtimeFailures),
            "repairs": Double(metrics.repairs),
            "leafModelCalls": Double(metrics.leafModelCalls),
            "leafPrompts": Double(metrics.leafPrompts),
            "corpusSearchCalls": Double(metrics.corpusSearchCalls),
            "corpusReadCalls": Double(metrics.corpusReadCalls),
            "contextReadBytes": Double(metrics.contextReadBytes),
            "estimatedModelTokens": Double(metrics.estimatedModelTokens),
            "evidenceReferences": Double(metrics.evidenceReferences),
        ]
    }
}

/// A transport the preflight uses: it proves no model call happens there.
private struct RLMScenarioRefusingTransport: ExperimentModelTransport {
    func generate(prompt _: String, tier _: ExperimentModelTier) async throws -> ExperimentGeneration {
        throw RLMFailure.rootModelFailed("preflight does not contact a provider")
    }
}

/// A read-only corpus over the manifest scope, matching the Stage 0 source.
struct RLMScenarioRepositorySource: RLMCorpusSource {
    static let workspaceID = "gnostic-repository"

    let root: String
    let prefixes: [String]

    func listFiles() async throws -> [RLMCorpusSourceFile] {
        enumerateFiles()
    }

    private func enumerateFiles() -> [RLMCorpusSourceFile] {
        let fileManager = FileManager.default
        var files: [RLMCorpusSourceFile] = []
        for prefix in prefixes {
            let base = (root as NSString).appendingPathComponent(prefix)
            guard let enumerator = fileManager.enumerator(atPath: base) else { continue }
            for case let relative as String in enumerator {
                guard relative.hasSuffix(".swift") || relative.hasSuffix(".md") || relative.hasSuffix(".json") else { continue }
                let absolute = (base as NSString).appendingPathComponent(relative)
                guard let attributes = try? fileManager.attributesOfItem(atPath: absolute),
                      let size = attributes[.size] as? Int else { continue }
                files.append(RLMCorpusSourceFile(path: "\(prefix)/\(relative)", byteCount: size))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    func readFile(at path: String) async throws -> RLMCorpusFileContent {
        let absolute = (root as NSString).appendingPathComponent(path)
        guard let data = FileManager.default.contents(atPath: absolute) else {
            throw RLMFailure.corpusSourceFailed("unreadable file '\(path)'")
        }
        return RLMCorpusFileContent(path: path, bytes: [UInt8](data))
    }
}

enum RLMScenarioHost {
    static var operatingSystem: String {
        #if os(Linux)
        "linux"
        #elseif os(macOS)
        "darwin"
        #else
        "unknown"
        #endif
    }

    static var architecture: String {
        #if arch(x86_64)
        "x86_64"
        #elseif arch(arm64)
        "arm64"
        #else
        "unknown"
        #endif
    }
}

struct RLMScenarioGit {
    let root: URL

    func head() -> String {
        run(["rev-parse", "HEAD"]) ?? "unknown"
    }

    func isClean() -> Bool {
        run(["status", "--porcelain"])?.isEmpty ?? false
    }

    private func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RLMScenarioPlanRenderer {
    static func render(plan: ExperimentPlan, existing: ExperimentRunArtifact?, outputPath: String) -> String {
        let manifest = plan.manifest
        let ceiling = plan.ceiling
        let tiers = manifest.regime.modelTiers
        var lines = [
            "RLM scenario \(manifest.segment) (manifest \(manifest.manifestVersion))",
            "  Provider: \(manifest.regime.provider) at \(manifest.regime.endpoint)",
            "  Root model: \(tiers["primary"] ?? "?"); leaf models: primary \(tiers["primary"] ?? "?"), utility \(tiers["utility"] ?? "?"), fast \(tiers["fast"] ?? "?")",
            "  Questions: \(manifest.caseIDs.joined(separator: ", ")) × \(manifest.repetitions) repetitions × \(manifest.arms.joined(separator: ", "))",
            "  Commit: \(manifest.gitCommit)\(manifest.workingTreeClean ? "" : " (working tree has uncommitted changes)")",
            "  Image: \(manifest.imageDigest ?? "unpinned host \(manifest.host)")",
            "  Corpus revision: \(manifest.corpusRevisionDigest ?? "none")",
            "  Artifact: \(outputPath)\(existing.map { " (resuming \($0.runs.count) recorded runs)" } ?? "")",
            "  Worst case: \(ceiling.runs) runs, ≤ \(ceiling.maximumModelCalls) model calls, ≤ \(ceiling.maximumEstimatedTokens) estimated tokens"
                + (ceiling.maximumEstimatedCostUSD.map { String(format: ", ≈ $%.2f at the higher of the given rates", $0) } ?? " (unpriced: flat-rate subscription)"),
        ]
        if let pilot = plan.pilot {
            let cost = manifest.pricing == nil ? "unpriced" : String(format: "$%.2f", pilot.projection.projectedCostUSD)
            lines.append("  Pilot projection for this matrix: \(pilot.projection.projectedRuns) runs, \(cost)\(pilot.projection.costComplete ? "" : " (lower bound: some calls reported no usage)")")
        }
        return lines.joined(separator: "\n")
    }

    static func summary(_ artifact: ExperimentRunArtifact) -> String {
        let completed = artifact.runs.filter { $0.outcome == "completed" }.count
        let usage = artifact.runs.map(\.totalUsage).reduce(ExperimentUsage(), +)
        let spend = artifact.manifest.pricing == nil
            ? "used \(usage.promptTokens) prompt and \(usage.completionTokens) completion tokens (unpriced)"
            : String(format: "spent $%.4f", artifact.costActualUSD)
        var lines = [
            "Status: \(artifact.status). \(completed) of \(artifact.runs.count) runs completed; \(spend)\(artifact.costComplete ? "" : " (lower bound)").",
        ]
        if let projection = artifact.costProjection {
            let perArm = projection.arms.map { String(format: "%@ ≈ %.0f calls, %.0f tokens per run", $0.arm, $0.meanModelCalls, $0.meanPromptTokens + $0.meanCompletionTokens) }
            lines.append("Projected full matrix: \(projection.projectedRuns) runs (\(perArm.joined(separator: "; ")))\(artifact.manifest.pricing == nil ? "" : String(format: ", $%.2f", projection.projectedCostUSD)). Accept this before running --stage matrix.")
        }
        return lines.joined(separator: "\n")
    }
}
