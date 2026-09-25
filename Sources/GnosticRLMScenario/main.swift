// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM
import GnosticRLMChibi
import GnosticRLMGuile
import GnosticRLMProcessWorker

#if os(Linux)
import Glibc
#endif

/// Stage 0 of the #354 evidence gate.
///
/// Runs the 12 frozen scenario questions deterministically through the scripted
/// engine and both Scheme executors, with no provider credentials and no spend,
/// and records M1–M6 and the digest parity required by the manifest.
@main
struct GnosticRLMScenario {
    static func main() async throws {
        let report = try await Stage0Harness().run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Questions

/// One frozen scenario question from `rlm-scenario-questions.md`.
struct ScenarioQuestion: Sendable {
    let id: String
    let question: String
    /// A single-token lexical query that resolves in the corpus scope.
    let query: String
    /// The frozen reference answer. All three arms use the same answer, and its
    /// normalized UTF-8 bytes are hashed into the report.
    let answer: String
}

enum ScenarioQuestions {
    static let corpusPrefixes = [
        "Sources/GnosticCore/Runtime",
        "Sources/GnosticRLM",
        "Documentation/Architecture",
    ]

    static let all: [ScenarioQuestion] = [
        ScenarioQuestion(
            id: "Q1",
            question: "What is Gnostic's host boundary, and which PositronicKit values may cross it?",
            query: "protocolMajor",
            answer: "Gnostic is a directly Axoloty-native Ascendant host, not a transport-neutral agent operating system. A narrow mandatory AscendantBackend contract owns execution for one Ascendant and exposes only the host services demonstrated Gnostic operations need; optional capabilities are separate, and interoperability is advertised per Ascendant instance and selected by protocolMajor and capability vocabulary, never by backend kind. PositronicKit native types stay inside the bundled backend, the explicit adapters, and the host bridges listed in ADR 0005; the Core-owned Workspace network contract uses ManifestJSONValue, and conversion lives in WorkspaceReferenceProjection and the adapter seams."
        ),
        ScenarioQuestion(
            id: "Q2",
            question: "How does Gnostic keep Timeline identity independent of backend transcript state?",
            query: "TimelineRecord",
            answer: "Timeline identity is Gnostic-owned. A backend may project a Timeline into private transcript/context state, but it cannot redefine or erase the Gnostic identity; PositronicKit TimelineRecord and AgentInstance are backend-private implementation details. Loss or replacement of a backend, or a backend change made while the Node is stopped, must not lose the Timeline identity."
        ),
        ScenarioQuestion(
            id: "Q3",
            question: "What is RuntimeEffectScope, and what authorities is it explicitly not?",
            query: "RuntimeEffectScope",
            answer: "RuntimeEffectScope is a structural ownership and cleanup boundary: adopted effects are released when the scope ends, and one live parent per child is enforced. It is explicitly not a dependency-injection container, a service locator, a configuration store, a dynamic loader, or a domain authority. Fitness tests pin its forbidden dependencies and its named owners, and a diagnostic-label test keeps dynamic or unsafe content out of scope labels."
        ),
        ScenarioQuestion(
            id: "Q4",
            question: "How does terminal Turn observation deliver an outcome, and what bounds a stuck observer?",
            query: "TerminalTurnObserving",
            answer: "It is a one-way, backend-neutral Core seam. Hosts install TerminalTurnObserving values through NodeRuntimeAdapters. A TerminalTurnRecord carries only Gnostic identity and a bounded TerminalTurnOutcome; Atlas, Shard, prompt, revision, and PositronicKit types stay outside the contract. Exact shutdown waits for Turn and lane settlement before closing the observation fence, then drains admitted observer deliveries up to observationDrainTimeout; only work outliving that window is cut off. A given observer receives at most one delivery per original identified terminal Turn, and only if it was admitted before the fence."
        ),
        ScenarioQuestion(
            id: "Q5",
            question: "Does a Timeline created at runtime have to survive a `gnostic serve` restart, and what exactly is promised across restarts?",
            query: "timelineUnavailable",
            answer: "No. In the current contract a runtime-created Timeline is process-scoped and does not have to survive a serve restart. What is promised is session/resume across an ACP-child restart against a live serve, not across a serve restart. Full durability would need both a node-scoped Gnostic Timeline identity store (separate from the manifest, which is never written back) and a durable backend TimelineRuntimeRepository. Until then, an orphaned session must fail session/resume with timelineUnavailable and be omitted from session/list rather than being recreated implicitly."
        ),
        ScenarioQuestion(
            id: "Q6",
            question: "What three layers let one Node host distinct Ascendant configurations, and what must not leak between them?",
            query: "ambiguousAscendant",
            answer: "The three layers are: (1) static composition at the composition root, which registers every backend kind and compiled-in Positronic extension and is shared by serve and config; (2) per-Ascendant selection through backend settings (backend.kind selects the factory; the backend-owned settings/secrets configure it; an extensions array selects contributions); and (3) the PositronicContribution seam, the only supported extension point for one Positronic Ascendant, bounded to additional tools plus at most one Turn context source. Routing is by Ascendant and Timeline identity, never by backend kind; selecting with no Ascendant ID on a multi-Ascendant Node fails with ambiguousAscendant. A lifecycle-unusable backend failure quarantines only its own Ascendant, and GnosticCore must not depend on the Atlas, RLM, or Letta targets."
        ),
        ScenarioQuestion(
            id: "Q7",
            question: "Who owns an RLM run's limits, and how may a caller change them?",
            query: "maxCellRepairs",
            answer: "The host owns RLMRunBudget, which fixes wall duration, root iterations, leaf model calls, estimated model tokens, corpus file/byte limits, context-read bytes, Scheme cell/output bytes, evidence references, chunks per read, search limit, and the recoverable-repair count (maxCellRepairs, default 3). A caller may only narrow these values with RLMRunBudgetRequest: narrowed(by:) takes the smaller host/requested value per field, nil keeps the host value, and resolve(host:request:) validates first. Negative values throw invalidToolArguments. No tool argument, root cell, or model response can enlarge a limit."
        ),
        ScenarioQuestion(
            id: "Q8",
            question: "Which RLM failures can be fed back to the root model for repair, and how is repairing bounded?",
            query: "isRecoverableCellFailure",
            answer: "Only recoverable cell failures can be fed back: cellRejected (validation rejected the cell before evaluation) and cellRuntimeFailed (the cell evaluated but raised a recoverable Scheme error), as reported by isRecoverableCellFailure. Every other failure is terminal. The root iteration containing the failed cell is already consumed, so the repair continuation advances the same root-iteration budget, and maxCellRepairs bounds the number of repairs in one run. A repair record carries a single-line reason bounded to 512 characters."
        ),
        ScenarioQuestion(
            id: "Q9",
            question: "What must an evidence reference satisfy to be accepted, and what happens when one is rejected?",
            query: "evidenceRejected",
            answer: "On finish, references are validated against the committed snapshot: the reference count must not exceed the budget; every chunk ID must be known; the referenced path must match the chunk's snapshot path; the line range must not be inverted and must be within the chunk's bounds. A rejection maps to evidenceRejected with the specific reason and terminates the run rather than completing with unverified evidence; the number of accepted references is recorded in run metrics."
        ),
        ScenarioQuestion(
            id: "Q10",
            question: "What access does the RLM harness have to corpus bytes, and what does the snapshot step guarantee?",
            query: "RLMCorpusSnapshotter",
            answer: "The harness never receives a Workspace path it can open directly; it sees only the read-only RLMCorpusSource seam (listFiles, readFile). The snapshotter captures an immutable RLMCorpusSnapshot before evaluation, enforcing the configured file-count and byte limits (tooManyFiles, corpusTooLarge) and recording any skipped files, so a run's evidence is validated against a stable corpus rather than live filesystem state."
        ),
        ScenarioQuestion(
            id: "Q11",
            question: "What does the shared executor seam own, and where do runtime differences live?",
            query: "RLMWorkerExecutor",
            answer: "RLMWorkerExecutor states only what differs between runtimes: a display name, whether the reviewed build supports the current platform, and how a configuration becomes an RLMWorkerLaunchSpec. Process supervision, the framed protocol, parent-side cell validation, host servicing, and cancellation and wall-time fences are shared. Each executor supplies its own launch, including host-owned process limits, so the shared worker session names no executor and branches on no executor-specific behavior. ADR 0012 offers both runtimes as first-class selectable executors and defers the default choice to measured impact."
        ),
        ScenarioQuestion(
            id: "Q12",
            question: "How is a backend failure contained, and how is retirement bounded?",
            query: "BackendRetirementSupervisor",
            answer: "An ordinary Turn failure leaves the backend healthy and usable; only a lifecycle-unusable failure quarantines the Ascendant whose backend failed, leaving the other Ascendants on the Node serving. Retirement is bounded by a deadline through the retirement supervisor and lifecycle coordinator: a retirement or rollback stage that exceeds its deadline is recorded as exceeded rather than blocking the Node, and the affected Ascendant is isolated instead of stalling the others."
        ),
    ]
}

// MARK: - Corpus source

/// A read-only corpus source over the repository's manifest scope.
struct RepositoryCorpusSource: RLMCorpusSource {
    let root: String
    let prefixes: [String]

    func listFiles() async throws -> [RLMCorpusSourceFile] {
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: absolute),
              let size = attributes[.size] as? Int,
              size <= 2 * 1_024 * 1_024 else {
            throw RLMFailure.corpusSourceFailed("missing or oversized file '\(path)'")
        }
        guard let data = FileManager.default.contents(atPath: absolute) else {
            throw RLMFailure.corpusSourceFailed("unreadable file '\(path)'")
        }
        return RLMCorpusFileContent(path: path, bytes: [UInt8](data))
    }
}

// MARK: - Root models

/// A root model that replays fixed Scheme cells, used for the two worker arms.
actor SchemeScriptRootModel: RLMRootModelClient {
    private let scripts: [String]
    private var index = 0

    init(scripts: [String]) {
        self.scripts = scripts
    }

    func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep {
        guard index < scripts.count else {
            return .invalid(reason: "root script exhausted")
        }
        let script = scripts[index]
        index += 1
        return .scheme(source: script)
    }
}

enum ScenarioScript {
    /// A generated cell whose only failure is recoverable, so the root model
    /// earns exactly one repair before the working cell runs.
    static let recoverableFailureCell = "(car '())"

    static func workingCell(_ question: ScenarioQuestion) -> String {
        """
        (let* ((hits (corpus-search "\(question.query)" 5))
               (ids (map (lambda (hit) (cdr (assq 'chunk-id hit))) hits)))
          (corpus-read-many ids)
          (finish "\(question.answer)" ids))
        """
    }
}

// MARK: - Harness

struct Stage0Harness {
    private static let budget = RLMRunBudget.standard
    private static let policy = RLMCorpusPolicy(allowedPathPrefixes: ScenarioQuestions.corpusPrefixes)

    func run() async throws -> Stage0Report {
        let root = Self.repositoryRoot()
        let source = RepositoryCorpusSource(root: root, prefixes: ScenarioQuestions.corpusPrefixes)
        let corpusSnapshot = try await RLMCorpusSnapshotter(policy: Self.policy).capture(
            from: source,
            workspaceID: "stage0-workspace",
            budget: Self.budget
        )

        var rows: [ScenarioRow] = []
        for question in ScenarioQuestions.all {
            let scripted = await runScripted(question: question, source: source)
            let guile = await runWorker(question: question, source: source, runtime: "guile")
            let chibi = await runWorker(question: question, source: source, runtime: "chibi")
            rows.append(
                ScenarioRow(
                    id: question.id,
                    question: question.question,
                    questionSHA256: Self.hashNormalizedText(question.question),
                    referenceAnswerSHA256: Self.hashNormalizedText(question.answer),
                    scripted: scripted,
                    guile: guile,
                    chibi: chibi
                )
            )
        }

        return Stage0Report(
            schemaVersion: 1,
            scenario: "rlm-scenario-questions-v1",
            manifestID: "rlm-scenario-manifest-v1",
            manifestVersion: "v6",
            hashNormalization: "SHA-256 over normalized plain-text UTF-8; Markdown inline-code delimiters are omitted and line-wrapped whitespace is collapsed.",
            questionSetSHA256: try Self.questionSetSHA256(root: root),
            questionSetPath: "Documentation/Experiments/rlm-scenario-questions.md",
            generatedAtUTC: ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_TIMESTAMP"] ?? Self.timestamp(),
            gitCommit: ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_COMMIT"],
            imageDigest: ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_IMAGE_DIGEST"],
            corpusRevisionDigest: corpusSnapshot.revisionDigest,
            corpusSnapshotID: corpusSnapshot.id,
            corpusFileCount: corpusSnapshot.files.count,
            corpusChunkCount: corpusSnapshot.chunks.count,
            corpusBytes: corpusSnapshot.totalBytes,
            corpusSkippedFileCount: corpusSnapshot.skipped.count,
            corpusScope: ScenarioQuestions.corpusPrefixes,
            budgets: Stage0BudgetDescription(Self.budget),
            executorBuilds: try Self.executorBuilds(),
            host: HostDescription.current,
            outcome: "stage-0-question-measurements",
            rows: rows
        )
    }

    private func runScripted(question: ScenarioQuestion, source: any RLMCorpusSource) async -> ArmMeasurement {
        let engine = RLMAnalysisEngine(
            budget: Self.budget,
            policy: Self.policy,
            rootModel: ScriptedRootModel(plan: [
                .search(query: question.query, limit: 5),
                .readPreviousSearchHits(maxChunks: 5),
                .finish(answer: question.answer),
            ]),
            leafModel: ScriptedLeafModel(defaultResponse: "evidence"),
            evaluator: ScriptedCellEvaluator()
        )
        let clock = ContinuousClock()
        let started = clock.now
        let result = await engine.run(question: question.question, workspaceID: "stage0-workspace", source: source)
        let elapsed = Self.milliseconds(started.duration(to: .now))
        return ArmMeasurement(
            runtime: "scripted-engine",
            status: "measured",
            startupMilliseconds: 0,
            evaluationMilliseconds: elapsed,
            runMilliseconds: elapsed,
            cancellationMilliseconds: nil,
            sampledPeakRSSBytes: nil,
            sampledCPUTimeMilliseconds: nil,
            outcome: Self.outcome(result.outcome),
            semanticDigest: Self.digest(result.outcome),
            rootIterations: result.metrics.rootIterations,
            repairs: result.metrics.repairs,
            rootCellRejections: result.metrics.rootCellRejections,
            runtimeFailures: result.metrics.runtimeFailures,
            evidenceReferences: result.metrics.evidenceReferences,
            repairRate: rate(repairs: result.metrics.repairs, rootIterations: result.metrics.rootIterations),
            snapshotID: result.snapshotID,
            corpusFiles: result.metrics.corpusFiles,
            corpusChunks: result.metrics.corpusChunks,
            corpusBytes: result.metrics.corpusBytes,
            unavailableReason: nil
        )
    }

    private func runWorker(
        question: ScenarioQuestion,
        source: any RLMCorpusSource,
        runtime: String
    ) async -> ArmMeasurement {
        let host = RLMWorkerHostState(
            leafModel: ScriptedLeafModel(defaultResponse: "evidence"),
            budget: Self.budget,
            tokenEstimator: RLMCharacterTokenEstimator(),
            progressSink: nil
        )
        let (driver, handle, timing) = makeDriverAndHandle(runtime: runtime, host: host)
        let evaluator = RLMWorkerCellEvaluator(driver: driver, host: host)
        let clock = ContinuousClock()
        let startupClock = clock.now
        do {
            try await evaluator.start()
        } catch {
            await evaluator.shutdown()
            return .unavailable(runtime: runtime, reason: String(describing: error))
        }
        let startup = Self.milliseconds(startupClock.duration(to: .now))
        let processID = await handle.processIdentifier
        let before = ProcessSample.read(processID)

        let engine = RLMAnalysisEngine(
            budget: Self.budget,
            policy: Self.policy,
            rootModel: SchemeScriptRootModel(scripts: [
                ScenarioScript.recoverableFailureCell,
                ScenarioScript.workingCell(question),
            ]),
            leafModel: ScriptedLeafModel(defaultResponse: "evidence"),
            evaluator: evaluator
        )
        let evaluationClock = clock.now
        let result = await engine.run(question: question.question, workspaceID: "stage0-workspace", source: source)
        let elapsed = Self.milliseconds(evaluationClock.duration(to: .now))
        let after = ProcessSample.read(processID)
        let cancellation = await measureCancellation(runtime: runtime)
        await evaluator.shutdown()

        return ArmMeasurement(
            runtime: runtime,
            status: "measured",
            startupMilliseconds: startup,
            evaluationMilliseconds: await timing.evaluationMilliseconds,
            runMilliseconds: elapsed,
            cancellationMilliseconds: cancellation.latencyMilliseconds,
            sampledPeakRSSBytes: [before, after].compactMap(\.rssBytes).max(),
            sampledCPUTimeMilliseconds: Self.cpuDelta(before: before, after: after),
            outcome: Self.outcome(result.outcome),
            semanticDigest: Self.digest(result.outcome),
            rootIterations: result.metrics.rootIterations,
            repairs: result.metrics.repairs,
            rootCellRejections: result.metrics.rootCellRejections,
            runtimeFailures: result.metrics.runtimeFailures,
            evidenceReferences: result.metrics.evidenceReferences,
            repairRate: rate(repairs: result.metrics.repairs, rootIterations: result.metrics.rootIterations),
            snapshotID: result.snapshotID,
            corpusFiles: result.metrics.corpusFiles,
            corpusChunks: result.metrics.corpusChunks,
            corpusBytes: result.metrics.corpusBytes,
            unavailableReason: nil
        )
    }

    private func measureCancellation(runtime: String) async -> CancellationMeasurement {
        let host = RLMWorkerHostState(
            leafModel: ScriptedLeafModel(defaultResponse: "evidence"),
            budget: Self.budget,
            tokenEstimator: RLMCharacterTokenEstimator(),
            progressSink: nil
        )
        let (driver, _, _) = makeDriverAndHandle(runtime: runtime, host: host)
        do {
            try await driver.start()
        } catch {
            await driver.shutdown()
            return CancellationMeasurement(latencyMilliseconds: nil, outcome: "unavailable")
        }
        let evaluation = Task { await driver.evaluate(source: "(define (spin n) (spin n)) (spin 0)") }
        try? await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let started = clock.now
        await driver.cancel()
        _ = await evaluation.value
        let latency = Self.milliseconds(started.duration(to: .now))
        await driver.shutdown()
        return CancellationMeasurement(latencyMilliseconds: latency, outcome: "cancelled")
    }

    private func makeDriverAndHandle(
        runtime: String,
        host: RLMWorkerHostState
    ) -> (any RLMWorkerDriver, RLMProcessWorkerDriverHandle, Stage0TimedWorkerDriver) {
        if runtime == "guile" {
            let configuration = RLMGuileWorkerConfiguration(
                runID: "stage0-guile",
                workerScriptPath: RLMGuileWorkerConfiguration.defaultWorkerScriptPath ?? "",
                executablePath: RLMGuileWorkerConfiguration.defaultExecutablePath
            )
            let driver = RLMProcessWorkerDriver<RLMGuileExecutor>(
                configuration: configuration,
                host: RLMGuileClosureHost { operation in try await host.service(operation) },
                wallTimeLimit: .milliseconds(Int64(configuration.wallDeadlineSeconds * 1_000)),
                outputLimitBytes: configuration.maxOutputBytes
            )
            let timing = Stage0TimedWorkerDriver(base: driver)
            return (timing, RLMProcessWorkerDriverHandle(driver: driver), timing)
        }

        let configuration = RLMChibiWorkerConfiguration(
            runID: "stage0-chibi",
            workerScriptPath: RLMChibiWorkerConfiguration.defaultWorkerScriptPath ?? "",
            executablePath: RLMChibiWorkerConfiguration.defaultExecutablePath
        )
        let driver = RLMProcessWorkerDriver<RLMChibiExecutor>(
            configuration: configuration,
            host: RLMChibiClosureHost { operation in try await host.service(operation) },
            wallTimeLimit: .milliseconds(Int64(configuration.wallDeadlineSeconds * 1_000)),
            outputLimitBytes: configuration.maxOutputBytes
        )
        let timing = Stage0TimedWorkerDriver(base: driver)
        return (timing, RLMProcessWorkerDriverHandle(driver: driver), timing)
    }

    private static func repositoryRoot() -> String {
        if let configured = ProcessInfo.processInfo.environment["GNOSTIC_SCENARIO_ROOT"], !configured.isEmpty {
            return configured
        }
        return FileManager.default.currentDirectoryPath
    }

    private static func outcome(_ outcome: RLMRunResult.Outcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case let .failed(failure): return "failed: \(failure)"
        case .cancelled: return "cancelled"
        case .fenced: return "fenced"
        }
    }

    private static func digest(_ outcome: RLMRunResult.Outcome) -> String? {
        guard case let .completed(answer, evidence) = outcome else { return nil }
        let value = answer + "|" + evidence.map(\.chunkID).joined(separator: ",")
        return RLMDigest.sha256Hex(value)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func questionSetSHA256(root: String) throws -> String {
        let path = (root as NSString).appendingPathComponent("Documentation/Experiments/rlm-scenario-questions.md")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return RLMDigest.sha256Hex([UInt8](data))
    }

    private static func executorBuilds() throws -> [Stage0ExecutorBuild] {
        let guile = RLMGuileWorkerConfiguration.defaultExecutablePath
        let chibi = RLMChibiWorkerConfiguration.defaultExecutablePath
        return [
            Stage0ExecutorBuild(
                name: "guile",
                path: guile,
                version: try commandVersion(path: guile, arguments: ["--version"]),
                binarySHA256: try executableSHA256(path: guile),
                buildFlags: ["system Guile 3.0 executable"]
            ),
            Stage0ExecutorBuild(
                name: "chibi",
                path: chibi,
                version: try commandVersion(path: chibi, arguments: ["-V"]),
                binarySHA256: try executableSHA256(path: chibi),
                buildFlags: [
                    "SEXP_USE_NO_FEATURES=1", "SEXP_USE_GREEN_THREADS=1", "SEXP_USE_CHECK_STACK=1",
                    "SEXP_USE_GROW_STACK=0", "SEXP_INIT_STACK_SIZE=8192", "SEXP_USE_FLONUMS=1",
                    "SEXP_USE_BIGNUMS=1", "SEXP_USE_MATH=1", "SEXP_USE_RATIOS=0", "SEXP_USE_COMPLEX=0",
                    "SEXP_USE_MODULES=0", "SEXP_USE_STATIC_LIBS_EMPTY=1", "SEXP_USE_LIMITED_MALLOC=1",
                    "SEXP_USE_STRICT_TOPLEVEL_BINDINGS=1", "SEXP_USE_DL=0", "chibi-cell-timeout.patch",
                ]
            ),
        ]
    }

    private static func commandVersion(path: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let firstLine = String(data: data, encoding: .utf8)?.split(separator: "\n").first else {
            throw RLMFailure.evaluatorFailed("could not read version from \(path)")
        }
        return String(firstLine)
    }

    private static func executableSHA256(path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return RLMDigest.sha256Hex([UInt8](data))
    }

    private static func hashNormalizedText(_ value: String) -> String {
        let withoutCodeMarkers = value.replacingOccurrences(of: "`", with: "")
        return RLMDigest.sha256Hex(withoutCodeMarkers.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func cpuDelta(before: ProcessSample, after: ProcessSample) -> Double? {
        guard let before = before.cpuMilliseconds, let after = after.cpuMilliseconds else { return nil }
        return max(0, after - before)
    }

    private func rate(repairs: Int, rootIterations: Int) -> Double? {
        guard rootIterations > 0 else { return nil }
        return Double(repairs) / Double(rootIterations)
    }
}

/// Holds the concrete driver so the harness can read its process identifier for
/// sampling while the evaluator sees only the `RLMWorkerDriver` protocol.
struct RLMProcessWorkerDriverHandle: Sendable {
    private let processIdentifierProvider: @Sendable () async -> Int32?

    init(driver: RLMProcessWorkerDriver<some RLMWorkerExecutor>) {
        self.processIdentifierProvider = { await driver.processIdentifier }
    }

    var processIdentifier: Int32? {
        get async { await processIdentifierProvider() }
    }
}

// MARK: - Process sampling

struct ProcessSample: Sendable {
    let rssBytes: Int?
    let cpuMilliseconds: Double?

    static func read(_ processID: Int32?) -> ProcessSample {
        guard let processID else { return ProcessSample(rssBytes: nil, cpuMilliseconds: nil) }
        #if os(Linux)
        let statusPath = "/proc/\(processID)/status"
        let statPath = "/proc/\(processID)/stat"
        let rss = (try? String(contentsOfFile: statusPath, encoding: .utf8))
            .flatMap { status in status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") } }
            .flatMap { line -> Int? in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, let kilobytes = Int(parts[1]) else { return nil }
                return kilobytes * 1_024
            }
        let cpu = (try? String(contentsOfFile: statPath, encoding: .utf8)).flatMap { stat -> Double? in
            guard let close = stat.lastIndex(of: ")") else { return nil }
            let fields = stat[stat.index(after: close)...].split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 12, let user = Int64(fields[11]), let system = Int64(fields[12]) else { return nil }
            let ticks = sysconf(Int32(_SC_CLK_TCK))
            guard ticks > 0 else { return nil }
            return Double(user + system) * 1_000 / Double(ticks)
        }
        return ProcessSample(rssBytes: rss, cpuMilliseconds: cpu)
        #else
        return ProcessSample(rssBytes: nil, cpuMilliseconds: nil)
        #endif
    }
}

// MARK: - Report

struct CancellationMeasurement: Codable, Sendable {
    let latencyMilliseconds: Double?
    let outcome: String?
}

actor Stage0TimedWorkerDriver: RLMWorkerDriver {
    private let base: any RLMWorkerDriver
    private var accumulatedEvaluationMilliseconds = 0.0

    init(base: any RLMWorkerDriver) {
        self.base = base
    }

    func start() async throws {
        try await base.start()
    }

    func evaluate(source: String) async -> RLMWorkerEvaluation {
        let started = ContinuousClock.now
        let result = await base.evaluate(source: source)
        let components = started.duration(to: .now).components
        accumulatedEvaluationMilliseconds += Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return result
    }

    func cancel() async { await base.cancel() }
    func shutdown() async { await base.shutdown() }

    var evaluationMilliseconds: Double { accumulatedEvaluationMilliseconds }
}

struct ArmMeasurement: Codable, Sendable {
    let runtime: String
    let status: String
    let startupMilliseconds: Double?
    let evaluationMilliseconds: Double?
    let runMilliseconds: Double?
    let cancellationMilliseconds: Double?
    let sampledPeakRSSBytes: Int?
    let sampledCPUTimeMilliseconds: Double?
    let outcome: String?
    let semanticDigest: String?
    let rootIterations: Int?
    let repairs: Int?
    let rootCellRejections: Int?
    let runtimeFailures: Int?
    let evidenceReferences: Int?
    let repairRate: Double?
    let snapshotID: String?
    let corpusFiles: Int?
    let corpusChunks: Int?
    let corpusBytes: Int?
    let unavailableReason: String?

    static func unavailable(runtime: String, reason: String) -> ArmMeasurement {
        ArmMeasurement(
            runtime: runtime,
            status: "unavailable",
            startupMilliseconds: nil,
            evaluationMilliseconds: nil,
            runMilliseconds: nil,
            cancellationMilliseconds: nil,
            sampledPeakRSSBytes: nil,
            sampledCPUTimeMilliseconds: nil,
            outcome: nil,
            semanticDigest: nil,
            rootIterations: nil,
            repairs: nil,
            rootCellRejections: nil,
            runtimeFailures: nil,
            evidenceReferences: nil,
            repairRate: nil,
            snapshotID: nil,
            corpusFiles: nil,
            corpusChunks: nil,
            corpusBytes: nil,
            unavailableReason: reason
        )
    }
}

struct ScenarioRow: Codable, Sendable {
    let id: String
    let question: String
    let questionSHA256: String
    let referenceAnswerSHA256: String
    let scripted: ArmMeasurement
    let guile: ArmMeasurement
    let chibi: ArmMeasurement
}

struct Stage0BudgetDescription: Codable, Sendable {
    let wallDurationMilliseconds: Double
    let rootIterations: Int
    let leafModelCalls: Int
    let estimatedModelTokens: Int
    let corpusFiles: Int
    let corpusFileBytes: Int
    let corpusBytes: Int
    let corpusBytesRead: Int
    let schemeCellBytes: Int
    let schemeOutputBytes: Int
    let evidenceReferences: Int
    let chunksPerRead: Int
    let searchLimit: Int
    let cellRepairs: Int

    init(_ budget: RLMRunBudget) {
        let duration = budget.maxWallDuration.components
        wallDurationMilliseconds = Double(duration.seconds) * 1_000
            + Double(duration.attoseconds) / 1_000_000_000_000_000
        rootIterations = budget.maxRootIterations
        leafModelCalls = budget.maxLeafModelCalls
        estimatedModelTokens = budget.maxEstimatedModelTokens
        corpusFiles = budget.maxCorpusFiles
        corpusFileBytes = budget.maxCorpusFileBytes
        corpusBytes = budget.maxCorpusBytes
        corpusBytesRead = budget.maxCorpusBytesRead
        schemeCellBytes = budget.maxSchemeCellBytes
        schemeOutputBytes = budget.maxSchemeOutputBytes
        evidenceReferences = budget.maxEvidenceReferences
        chunksPerRead = budget.maxChunksPerRead
        searchLimit = budget.maxSearchLimit
        cellRepairs = budget.maxCellRepairs
    }
}

struct Stage0ExecutorBuild: Codable, Sendable {
    let name: String
    let path: String
    let version: String
    let binarySHA256: String
    let buildFlags: [String]
}

struct HostDescription: Codable, Sendable {
    let operatingSystem: String
    let architecture: String

    static var current: HostDescription {
        #if os(Linux)
        let operatingSystem = "linux"
        #elseif os(macOS)
        let operatingSystem = "macos"
        #else
        let operatingSystem = "other"
        #endif
        #if arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unknown"
        #endif
        return HostDescription(operatingSystem: operatingSystem, architecture: architecture)
    }
}

struct Stage0Report: Codable, Sendable {
    let schemaVersion: Int
    let scenario: String
    let manifestID: String
    let manifestVersion: String
    let hashNormalization: String
    let questionSetSHA256: String
    let questionSetPath: String
    let generatedAtUTC: String
    let gitCommit: String?
    let imageDigest: String?
    let corpusRevisionDigest: String
    let corpusSnapshotID: String
    let corpusFileCount: Int
    let corpusChunkCount: Int
    let corpusBytes: Int
    let corpusSkippedFileCount: Int
    let corpusScope: [String]
    let budgets: Stage0BudgetDescription
    let executorBuilds: [Stage0ExecutorBuild]
    var validationEvidence: [String: Stage0ValidationEvidence]?
    let host: HostDescription
    let outcome: String
    let rows: [ScenarioRow]
}

struct Stage0ValidationEvidence: Codable, Sendable {
    let status: String
    let suites: [Stage0SuiteEvidence]
}

struct Stage0SuiteEvidence: Codable, Sendable {
    let suite: String
    let filter: String
    let tests: Int
    let suites: Int
    let logSHA256: String
}
