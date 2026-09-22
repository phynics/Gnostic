// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM
import GnosticRLMChibi
import GnosticRLMGuile

#if os(Linux)
import Glibc
#endif

@main
struct GnosticRLMBenchmark {
    static func main() async throws {
        let report = await RLMRuntimeBenchmark().run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
    }
}

private struct RLMRuntimeBenchmark {
    private static let scenarioName = "bounded-repository-fixture-v1"
    private static let workspaceID = "benchmark-workspace"
    private static let question = "Identify the generation fence and retirement boundary."

    private static let schemeSource = """
    (let* ((hits (corpus-search "generation retirement" 4))
           (chunks (corpus-read-many (list "c-1" "c-2")))
           (answers (lm-query-batched (list "extract the fence" "extract the lease") 'fast)))
      (finish (string-join answers "\\n") (list "c-1" "c-2")))
    """

    private static let infiniteSource = "(define (spin n) (spin n)) (spin 0)"

    func run() async -> BenchmarkReport {
        let scripted = await runScriptedEngine()
        let guile = await measureWorker(runtime: "guile", make: makeGuileDriver)
        let chibi = await measureWorker(runtime: "chibi", make: makeChibiDriver)

        return BenchmarkReport(
            schemaVersion: 1,
            benchmark: Self.scenarioName,
            generatedAtUTC: ProcessInfo.processInfo.environment["GNOSTIC_BENCHMARK_TIMESTAMP"] ?? Self.timestamp(),
            gitCommit: ProcessInfo.processInfo.environment["GNOSTIC_BENCHMARK_COMMIT"],
            host: HostDescription.current,
            outcome: "CONTINUE_EXPERIMENT",
            decisionRationale: "The repository gate has deterministic operational data, but no live provider quality, monetary cost, or macOS Chibi data. Promotion is bounded until those measurements are captured with the same fixture and model family.",
            measurements: [scripted, guile, chibi],
            unavailableMeasurements: [
                UnavailableMeasurement(
                    name: "ordinary-positronic-analysis",
                    reason: "requires provider credentials and a stable live model configuration; excluded from the deterministic repository gate"
                ),
                UnavailableMeasurement(
                    name: "ordinary-positronic-bounded-retrieval",
                    reason: "no bounded-retrieval implementation exists in the current product; this comparison remains a follow-up experiment"
                ),
                UnavailableMeasurement(
                    name: "live-answer-quality-and-cost",
                    reason: "not measurable without provider credentials, a fixed model family, and an approved evaluation corpus"
                ),
                UnavailableMeasurement(
                    name: "macos-chibi-packaging",
                    reason: "Chibi is Linux-only in the pinned build and macOS evidence is deferred by issue #181"
                ),
            ]
        )
    }

    private func runScriptedEngine() async -> RuntimeMeasurement {
        let started = ContinuousClock.now
        let engine = RLMAnalysisEngine(
            budget: .standard,
            rootModel: ScriptedRootModel(plan: [
                .search(query: "generation retirement", limit: 4),
                .readPreviousSearchHits(maxChunks: 2),
                .leafScan(tier: .fast, instruction: "Extract the fence and lease."),
                .finish(answer: "The runtime advances its generation and invalidates the lease."),
            ]),
            leafModel: ScriptedLeafModel(defaultResponse: "The generation fence rejects stale completions.")
        )
        let result = await engine.run(
            question: Self.question,
            workspaceID: Self.workspaceID,
            source: Self.corpusSource()
        )
        let elapsed = milliseconds(started.duration(to: .now))
        let outcome = outcomeDescription(result.outcome)
        let digest = semanticDigest(result.outcome)
        return RuntimeMeasurement(
            runtime: "scripted-engine",
            status: "measured",
            startupMilliseconds: 0,
            evaluationMilliseconds: elapsed,
            cancellationMilliseconds: nil,
            sampledPeakRSSBytes: nil,
            sampledCPUTimeMilliseconds: nil,
            sampleCount: 0,
            evaluationOutcome: outcome,
            cancellationOutcome: nil,
            semanticResultDigest: digest,
            rootIterations: result.metrics.rootIterations,
            leafModelCalls: result.metrics.leafModelCalls,
            leafPrompts: result.metrics.leafPrompts,
            corpusFiles: result.metrics.corpusFiles,
            corpusChunks: result.metrics.corpusChunks,
            corpusBytes: result.metrics.corpusBytes,
            contextReadBytes: result.metrics.contextReadBytes,
            estimatedModelTokens: result.metrics.estimatedModelTokens,
            hostOperations: nil,
            unavailableReason: nil
        )
    }

    private func measureWorker(
        runtime: String,
        make: @escaping @Sendable () -> (any BenchmarkWorkerDriver, BenchmarkHost)
    ) async -> RuntimeMeasurement {
        let (driver, host) = make()
        let startupClock = ContinuousClock.now
        do {
            try await driver.start()
        } catch {
            await driver.shutdown()
            return .unavailable(runtime: runtime, reason: String(describing: error))
        }
        let startupMilliseconds = milliseconds(startupClock.duration(to: .now))
        let processID = await driver.processIdentifier
        let before = ProcessSample.read(processID)

        let evaluationClock = ContinuousClock.now
        let evaluation = await driver.evaluate(source: Self.schemeSource)
        let evaluationMilliseconds = milliseconds(evaluationClock.duration(to: .now))
        let after = ProcessSample.read(processID)
        await driver.shutdown()

        let cancellation = await measureCancellation(make: make)
        let samples = [before, after]
        return RuntimeMeasurement(
            runtime: runtime,
            status: "measured",
            startupMilliseconds: startupMilliseconds,
            evaluationMilliseconds: evaluationMilliseconds,
            cancellationMilliseconds: cancellation.latencyMilliseconds,
            sampledPeakRSSBytes: samples.compactMap(\.rssBytes).max(),
            sampledCPUTimeMilliseconds: Self.cpuDelta(before: before, after: after),
            sampleCount: samples.filter { $0.rssBytes != nil || $0.cpuMilliseconds != nil }.count,
            evaluationOutcome: evaluation.outcome,
            cancellationOutcome: cancellation.outcome,
            semanticResultDigest: evaluation.semanticDigest,
            rootIterations: nil,
            leafModelCalls: nil,
            leafPrompts: await host.leafPrompts,
            corpusFiles: nil,
            corpusChunks: nil,
            corpusBytes: nil,
            contextReadBytes: await host.bytesRead,
            estimatedModelTokens: nil,
            hostOperations: await host.operationCount,
            unavailableReason: nil
        )
    }

    private func measureCancellation(
        make: @escaping @Sendable () -> (any BenchmarkWorkerDriver, BenchmarkHost)
    ) async -> CancellationMeasurement {
        let (driver, _) = make()
        do {
            try await driver.start()
        } catch {
            await driver.shutdown()
            return CancellationMeasurement(latencyMilliseconds: nil, outcome: "unavailable: \(error)")
        }
        let evaluation = Task { await driver.evaluate(source: Self.infiniteSource) }
        try? await Task.sleep(for: .milliseconds(50))
        let cancellationClock = ContinuousClock.now
        await driver.cancel()
        let result = await evaluation.value
        let latency = milliseconds(cancellationClock.duration(to: .now))
        await driver.shutdown()
        return CancellationMeasurement(latencyMilliseconds: latency, outcome: result.outcome)
    }

    private func makeGuileDriver() -> (any BenchmarkWorkerDriver, BenchmarkHost) {
        let host = BenchmarkHost()
        let session = RLMGuileWorkerSession(
            configuration: RLMGuileWorkerConfiguration(
                runID: "benchmark-guile",
                workerScriptPath: Self.scriptPath("GuileRLMWorker/worker.scm"),
                executablePath: RLMGuileWorkerConfiguration.defaultExecutablePath
            ),
            host: RLMGuileClosureHost { operation in
                try await host.service(operation)
            }
        )
        return (GuileBenchmarkDriver(session: session), host)
    }

    private func makeChibiDriver() -> (any BenchmarkWorkerDriver, BenchmarkHost) {
        let host = BenchmarkHost()
        let session = RLMChibiWorkerSession(
            configuration: RLMChibiWorkerConfiguration(
                runID: "benchmark-chibi",
                workerScriptPath: Self.scriptPath("ChibiRLMWorker/worker.scm"),
                executablePath: RLMChibiWorkerConfiguration.defaultExecutablePath
            ),
            host: RLMChibiClosureHost { operation in
                try await host.service(operation)
            }
        )
        return (ChibiBenchmarkDriver(session: session), host)
    }

    private static func corpusSource() -> RLMInMemoryCorpusSource {
        RLMInMemoryCorpusSource(textFiles: [
            "Sources/Runtime/Lease.swift": "func invalidateLease() { generation += 1 }\n",
            "Sources/Runtime/Fence.swift": "func accepts(_ generation: UInt64) -> Bool { generation == current }\n",
            "Documentation/retirement.md": "Retirement invalidates the lease and fences stale completions.\n",
            "README.md": "Gnostic runtime lifecycle fixture.\n",
        ])
    }

    private static func scriptPath(_ relativePath: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Experiments")
            .appendingPathComponent(relativePath)
            .path
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Self.milliseconds(duration)
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

    private func outcomeDescription(_ outcome: RLMRunResult.Outcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case let .failed(failure): return "failed: \(failure)"
        case .cancelled: return "cancelled"
        case .fenced: return "fenced"
        }
    }

    private func semanticDigest(_ outcome: RLMRunResult.Outcome) -> String? {
        guard case let .completed(answer, evidence) = outcome else { return nil }
        let value = answer + "|" + evidence.map(\.chunkID).joined(separator: ",")
        return RLMDigest.sha256Hex(value)
    }
}

private protocol BenchmarkWorkerDriver: Sendable {
    func start() async throws
    func evaluate(source: String) async -> BenchmarkEvaluation
    func cancel() async
    func shutdown() async
    var processIdentifier: Int32? { get async }
}

private struct BenchmarkEvaluation: Sendable {
    let outcome: String
    let semanticDigest: String?
}

private struct GuileBenchmarkDriver: BenchmarkWorkerDriver {
    let session: RLMGuileWorkerSession

    func start() async throws { try await session.start() }

    func evaluate(source: String) async -> BenchmarkEvaluation {
        switch await session.evaluate(source: source) {
        case let .value(value):
            return BenchmarkEvaluation(outcome: "value", semanticDigest: value.map { RLMDigest.sha256Hex($0.written) })
        case let .finished(answer, evidence):
            return BenchmarkEvaluation(outcome: "finished", semanticDigest: RLMDigest.sha256Hex(answer + "|" + evidence.joined(separator: ",")))
        case let .schemeFailed(message): return BenchmarkEvaluation(outcome: "scheme-failed: \(message)", semanticDigest: nil)
        case let .cellRejected(message): return BenchmarkEvaluation(outcome: "cell-rejected: \(message)", semanticDigest: nil)
        case .timedOut: return BenchmarkEvaluation(outcome: "timed-out", semanticDigest: nil)
        case .outputLimitReached: return BenchmarkEvaluation(outcome: "output-limit", semanticDigest: nil)
        case let .hostResultRejected(message): return BenchmarkEvaluation(outcome: "host-result-rejected: \(message)", semanticDigest: nil)
        case .cancelled: return BenchmarkEvaluation(outcome: "cancelled", semanticDigest: nil)
        case .fenced: return BenchmarkEvaluation(outcome: "fenced", semanticDigest: nil)
        case let .workerExited(code): return BenchmarkEvaluation(outcome: "worker-exited: \(code)", semanticDigest: nil)
        case let .protocolViolation(message): return BenchmarkEvaluation(outcome: "protocol-violation: \(message)", semanticDigest: nil)
        case .unsupportedPlatform: return BenchmarkEvaluation(outcome: "unsupported-platform", semanticDigest: nil)
        }
    }

    func cancel() async { await session.cancel() }
    func shutdown() async { await session.shutdown() }
    var processIdentifier: Int32? { get async { await session.processIdentifier } }
}

private struct ChibiBenchmarkDriver: BenchmarkWorkerDriver {
    let session: RLMChibiWorkerSession

    func start() async throws { try await session.start() }

    func evaluate(source: String) async -> BenchmarkEvaluation {
        switch await session.evaluate(source: source) {
        case let .value(value):
            return BenchmarkEvaluation(outcome: "value", semanticDigest: value.map { RLMDigest.sha256Hex($0.written) })
        case let .finished(answer, evidence):
            return BenchmarkEvaluation(outcome: "finished", semanticDigest: RLMDigest.sha256Hex(answer + "|" + evidence.joined(separator: ",")))
        case let .schemeFailed(message): return BenchmarkEvaluation(outcome: "scheme-failed: \(message)", semanticDigest: nil)
        case let .cellRejected(message): return BenchmarkEvaluation(outcome: "cell-rejected: \(message)", semanticDigest: nil)
        case .timedOut: return BenchmarkEvaluation(outcome: "timed-out", semanticDigest: nil)
        case .outputLimitReached: return BenchmarkEvaluation(outcome: "output-limit", semanticDigest: nil)
        case let .hostResultRejected(message): return BenchmarkEvaluation(outcome: "host-result-rejected: \(message)", semanticDigest: nil)
        case .cancelled: return BenchmarkEvaluation(outcome: "cancelled", semanticDigest: nil)
        case .fenced: return BenchmarkEvaluation(outcome: "fenced", semanticDigest: nil)
        case let .workerExited(code): return BenchmarkEvaluation(outcome: "worker-exited: \(code)", semanticDigest: nil)
        case let .protocolViolation(message): return BenchmarkEvaluation(outcome: "protocol-violation: \(message)", semanticDigest: nil)
        case .unsupportedPlatform: return BenchmarkEvaluation(outcome: "unsupported-platform", semanticDigest: nil)
        }
    }

    func cancel() async { await session.cancel() }
    func shutdown() async { await session.shutdown() }
    var processIdentifier: Int32? { get async { await session.processIdentifier } }
}

private actor BenchmarkHost {
    private(set) var operationCount = 0
    private(set) var leafPrompts = 0
    private(set) var bytesRead = 0

    func service(_ operation: RLMHostOperation) throws -> RLMHostObservation {
        operationCount += 1
        switch operation {
        case let .corpusSearch(query, limit):
            let hits = [
                RLMSearchHit(chunkID: "c-1", path: "Sources/Runtime/Lease.swift", startLine: 1, endLine: 1, preview: query, score: 1),
                RLMSearchHit(chunkID: "c-2", path: "Sources/Runtime/Fence.swift", startLine: 1, endLine: 1, preview: query, score: 0),
            ].prefix(max(0, limit))
            let result = Array(hits)
            let read = result.reduce(0) { $0 + $1.preview.utf8.count }
            bytesRead += read
            return .corpusSearch(hits: result, bytesRead: read)
        case let .corpusRead(chunkIDs):
            let chunks = chunkIDs.map { id in
                RLMCorpusChunk(
                    id: id,
                    path: id == "c-1" ? "Sources/Runtime/Lease.swift" : "Sources/Runtime/Fence.swift",
                    startLine: 1,
                    endLine: 1,
                    content: id == "c-1" ? "invalidate lease" : "fence generation",
                    byteCount: 16,
                    digest: "benchmark"
                )
            }
            let read = chunks.reduce(0) { $0 + $1.byteCount }
            bytesRead += read
            return .corpusRead(chunks: chunks, bytesRead: read)
        case let .leafQuery(prompts, _):
            leafPrompts += prompts.count
            return .leaf(responses: prompts.map { "evidence:\($0)" }, estimatedTokens: prompts.count)
        case .progress:
            return .progress
        case .finish:
            throw RLMFailure.evaluatorFailed("finish must not be serviced by the benchmark host")
        }
    }
}

private struct ProcessSample: Sendable {
    let rssBytes: Int?
    let cpuMilliseconds: Double?

    static func read(_ processID: Int32?) -> ProcessSample {
        guard let processID else { return ProcessSample(rssBytes: nil, cpuMilliseconds: nil) }
        #if os(Linux)
        let statusPath = "/proc/\(processID)/status"
        let statPath = "/proc/\(processID)/stat"
        let rss = (try? String(contentsOfFile: statusPath, encoding: .utf8))
            .flatMap { status in
                status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") }
            }
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

private struct CancellationMeasurement: Codable, Sendable {
    let latencyMilliseconds: Double?
    let outcome: String?
}

private struct RuntimeMeasurement: Codable, Sendable {
    let runtime: String
    let status: String
    let startupMilliseconds: Double?
    let evaluationMilliseconds: Double?
    let cancellationMilliseconds: Double?
    let sampledPeakRSSBytes: Int?
    let sampledCPUTimeMilliseconds: Double?
    let sampleCount: Int
    let evaluationOutcome: String?
    let cancellationOutcome: String?
    let semanticResultDigest: String?
    let rootIterations: Int?
    let leafModelCalls: Int?
    let leafPrompts: Int?
    let corpusFiles: Int?
    let corpusChunks: Int?
    let corpusBytes: Int?
    let contextReadBytes: Int?
    let estimatedModelTokens: Int?
    let hostOperations: Int?
    let unavailableReason: String?

    static func unavailable(runtime: String, reason: String) -> RuntimeMeasurement {
        RuntimeMeasurement(
            runtime: runtime,
            status: "unavailable",
            startupMilliseconds: nil,
            evaluationMilliseconds: nil,
            cancellationMilliseconds: nil,
            sampledPeakRSSBytes: nil,
            sampledCPUTimeMilliseconds: nil,
            sampleCount: 0,
            evaluationOutcome: nil,
            cancellationOutcome: nil,
            semanticResultDigest: nil,
            rootIterations: nil,
            leafModelCalls: nil,
            leafPrompts: nil,
            corpusFiles: nil,
            corpusChunks: nil,
            corpusBytes: nil,
            contextReadBytes: nil,
            estimatedModelTokens: nil,
            hostOperations: nil,
            unavailableReason: reason
        )
    }
}

private struct UnavailableMeasurement: Codable, Sendable {
    let name: String
    let reason: String
}

private struct HostDescription: Codable, Sendable {
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

private struct BenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let benchmark: String
    let generatedAtUTC: String
    let gitCommit: String?
    let host: HostDescription
    let outcome: String
    let decisionRationale: String
    let measurements: [RuntimeMeasurement]
    let unavailableMeasurements: [UnavailableMeasurement]
}
