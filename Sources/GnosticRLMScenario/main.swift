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
    /// The frozen question text, normalized as the manifest §7 hash requires.
    let question: String
    /// A single-token lexical query that resolves in the corpus scope.
    let query: String
    /// The frozen reference answer, normalized the same way. All three arms use
    /// the same answer, and its UTF-8 bytes are hashed into the report.
    let answer: String
}

/// Reads the question and reference-answer text from the frozen file, so
/// Stage 0 measures the approved wording verbatim (manifest §1 and §7).
enum ScenarioQuestions {
    static let relativePath = "Documentation/Experiments/rlm-scenario-questions.md"
    /// The SHA-256 of the approved question set.
    static let pinnedSHA256 = "5d57d96fd84a2afe7c9f303325cc6c8dd53138a8717a195b1a25ecaa2cc89475"
    static let corpusPrefixes = [
        "Sources/GnosticCore/Runtime",
        "Sources/GnosticRLM",
        "Documentation/Architecture",
    ]

    /// Stage 0's own input: one single-token lexical query per question that
    /// resolves in the corpus scope. The frozen file does not define these.
    static let queries: [String: String] = [
        "Q1": "protocolMajor",
        "Q2": "TimelineRecord",
        "Q3": "RuntimeEffectScope",
        "Q4": "TerminalTurnObserving",
        "Q5": "timelineUnavailable",
        "Q6": "ambiguousAscendant",
        "Q7": "maxCellRepairs",
        "Q8": "isRecoverableCellFailure",
        "Q9": "evidenceRejected",
        "Q10": "RLMCorpusSnapshotter",
        "Q11": "RLMWorkerExecutor",
        "Q12": "BackendRetirementSupervisor",
    ]

    static func load(root: String) throws -> (questions: [ScenarioQuestion], sha256: String) {
        let path = (root as NSString).appendingPathComponent(relativePath)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = RLMDigest.sha256Hex([UInt8](data))
        guard digest == pinnedSHA256 else {
            throw RLMFailure.corpusSourceFailed(
                "the frozen question set changed (expected SHA-256 \(pinnedSHA256), found \(digest))"
            )
        }
        return (try parse(String(decoding: data, as: UTF8.self)), digest)
    }

    /// Parses `## Qn — …` sections into their question and reference answer.
    static func parse(_ text: String) throws -> [ScenarioQuestion] {
        let questions = try text.components(separatedBy: "\n## Q").dropFirst().map { section in
            let id = "Q" + section.prefix { $0.isNumber }
            guard let question = field("Question", in: section),
                  let answer = field("Reference answer", in: section),
                  let query = queries[id] else {
                throw RLMFailure.corpusSourceFailed("\(id) is missing a question, reference answer, or Stage 0 query")
            }
            return ScenarioQuestion(id: id, question: normalized(question), query: query, answer: normalized(answer))
        }
        guard questions.map(\.id) == (1...12).map({ "Q\($0)" }) else {
            throw RLMFailure.corpusSourceFailed("expected Q1 through Q12, found \(questions.map(\.id))")
        }
        return questions
    }

    /// The manifest §7 normalization: inline-code delimiters dropped and
    /// line-wrapped whitespace collapsed.
    static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func field(_ name: String, in section: String) -> String? {
        guard let start = section.range(of: "**\(name).**") else { return nil }
        let rest = section[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex)])
    }
}

// MARK: - Corpus source

/// A read-only corpus source over the repository's manifest scope.
struct RepositoryCorpusSource: RLMCorpusSource {
    let root: String
    let prefixes: [String]

    func listFiles() async throws -> [RLMCorpusSourceFile] {
        enumerateFiles()
    }

    /// `FileManager`'s enumerator is unavailable from async contexts on
    /// Darwin, so the walk stays synchronous.
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
          (finish "\(schemeString(question.answer))" ids))
        """
    }

    private static func schemeString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Harness

struct Stage0Harness {
    private static let budget = RLMRunBudget.standard
    private static let policy = RLMCorpusPolicy(allowedPathPrefixes: ScenarioQuestions.corpusPrefixes)

    func run() async throws -> Stage0Report {
        let root = Self.repositoryRoot()
        let questionSet = try ScenarioQuestions.load(root: root)
        let source = RepositoryCorpusSource(root: root, prefixes: ScenarioQuestions.corpusPrefixes)
        let corpusSnapshot = try await RLMCorpusSnapshotter(policy: Self.policy).capture(
            from: source,
            workspaceID: "stage0-workspace",
            budget: Self.budget
        )

        var rows: [ScenarioRow] = []
        for question in questionSet.questions {
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
            questionSetSHA256: questionSet.sha256,
            questionSetPath: ScenarioQuestions.relativePath,
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
        RLMDigest.sha256Hex(ScenarioQuestions.normalized(value))
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
