// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM
import GnosticRLMProcessWorker
import GnosticRLMWorkerSupport

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
        let guile = await measureWorker(runtime: "guile", make: { makeDriver(.guile) })
        let chibi = await measureWorker(runtime: "chibi", make: { makeDriver(.chibi) })

        return BenchmarkReport(
            schemaVersion: 1,
            benchmark: Self.scenarioName,
            generatedAtUTC: ProcessInfo.processInfo.environment["GNOSTIC_BENCHMARK_TIMESTAMP"] ?? Self.timestamp(),
            gitCommit: ProcessInfo.processInfo.environment["GNOSTIC_BENCHMARK_COMMIT"],
            host: RLMHostDescription.current,
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
                UnavailableMeasurement(
                    name: "generated-cell-repair-rate",
                    reason: "the fixture uses a fixed valid cell and does not measure root-model repair attempts; this remains a follow-up under issue #181"
                ),
                UnavailableMeasurement(
                    name: "malicious-program-safety",
                    reason: "worker conformance and malicious-program suites are owned by issues #178 and #179; this benchmark does not replay or aggregate those fixtures"
                ),
                UnavailableMeasurement(
                    name: "heap-and-loop-containment",
                    reason: "worker limits and containment suites are covered by issues #178 and #179, while this short fixture records no stress distribution or heap profile"
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
        let before = RLMWorkerProcessSample.read(processID)

        let evaluationClock = ContinuousClock.now
        let evaluation = await driver.evaluate(source: Self.schemeSource)
        let evaluationMilliseconds = milliseconds(evaluationClock.duration(to: .now))
        let after = RLMWorkerProcessSample.read(processID)
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
            sampledCPUTimeMilliseconds: RLMWorkerProcessSample.cpuDelta(before: before, after: after),
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
    ) async -> RLMCancellationMeasurement {
        let (driver, _) = make()
        do {
            try await driver.start()
        } catch {
            await driver.shutdown()
            return RLMCancellationMeasurement(latencyMilliseconds: nil, outcome: "unavailable: \(error)")
        }
        let evaluation = Task { await driver.evaluate(source: Self.infiniteSource) }
        try? await Task.sleep(for: .milliseconds(50))
        let cancellationClock = ContinuousClock.now
        await driver.cancel()
        let result = await evaluation.value
        let latency = milliseconds(cancellationClock.duration(to: .now))
        await driver.shutdown()
        return RLMCancellationMeasurement(latencyMilliseconds: latency, outcome: result.outcome)
    }

    /// Builds one measured worker through the shared factory. An empty script
    /// path is kept on purpose: an unavailable worker is recorded as a
    /// measurement by the caller's start failure.
    private func makeDriver(_ selection: RLMWorkerSelection) -> (any BenchmarkWorkerDriver, BenchmarkHost) {
        let host = BenchmarkHost()
        let handle = RLMWorkerFactory.makeHandle(
            selection: selection,
            runID: "benchmark-\(selection.rawValue)",
            host: RLMWorkerClosureHost { operation in try await host.service(operation) },
            workerScriptPath: RLMWorkerFactory.scriptPath(for: selection) ?? ""
        )
        return (BenchmarkProcessDriver(handle: handle), host)
    }

    private static func corpusSource() -> RLMInMemoryCorpusSource {
        RLMInMemoryCorpusSource(textFiles: [
            "Sources/Runtime/Lease.swift": "func invalidateLease() { generation += 1 }\n",
            "Sources/Runtime/Fence.swift": "func accepts(_ generation: UInt64) -> Bool { generation == current }\n",
            "Documentation/retirement.md": "Retirement invalidates the lease and fences stale completions.\n",
            "README.md": "Gnostic runtime lifecycle fixture.\n",
        ])
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func milliseconds(_ duration: Duration) -> Double {
        RLMWorkerMeasurement.milliseconds(duration)
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

private extension BenchmarkEvaluation {
    init(_ evaluation: RLMWorkerEvaluation) {
        switch evaluation {
        case let .value(value):
            self.init(outcome: "value", semanticDigest: value.map { RLMDigest.sha256Hex($0.written) })
        case let .finished(answer, evidence):
            self.init(outcome: "finished", semanticDigest: RLMDigest.sha256Hex(answer + "|" + evidence.joined(separator: ",")))
        case let .failed(failure):
            self.init(outcome: "failed: \(failure)", semanticDigest: nil)
        case .cancelled:
            self.init(outcome: "cancelled", semanticDigest: nil)
        case .fenced:
            self.init(outcome: "fenced", semanticDigest: nil)
        case .unsupported:
            self.init(outcome: "unsupported-platform", semanticDigest: nil)
        }
    }
}

private struct BenchmarkProcessDriver: BenchmarkWorkerDriver {
    let handle: RLMWorkerDriverHandle

    func start() async throws { try await handle.driver.start() }

    func evaluate(source: String) async -> BenchmarkEvaluation {
        BenchmarkEvaluation(await handle.driver.evaluate(source: source))
    }

    func cancel() async { await handle.driver.cancel() }
    func shutdown() async { await handle.driver.shutdown() }
    var processIdentifier: Int32? { get async { await handle.processIdentifier } }
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

private struct BenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let benchmark: String
    let generatedAtUTC: String
    let gitCommit: String?
    let host: RLMHostDescription
    let outcome: String
    let decisionRationale: String
    let measurements: [RuntimeMeasurement]
    let unavailableMeasurements: [UnavailableMeasurement]
}
