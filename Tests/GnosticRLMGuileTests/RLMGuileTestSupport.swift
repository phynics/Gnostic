// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM
import GnosticRLMGuile

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum RLMGuileTestSupport {
    static var guilePath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["GNOSTIC_GUILE"],
            "/usr/bin/guile",
            "/opt/homebrew/bin/guile",
            "/usr/local/bin/guile",
        ]
        for candidate in candidates {
            guard let candidate, FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return nil
    }

    static var workerScriptPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Experiments/GuileRLMWorker/worker.scm")
            .path
    }

    static var isAvailable: Bool {
        guilePath != nil && FileManager.default.fileExists(atPath: workerScriptPath)
    }

    static func session(
        host: any RLMGuileHost,
        runID: String = UUID().uuidString,
        cancellation: RLMCancellationToken = RLMCancellationToken(),
        configure: (inout RLMGuileWorkerConfiguration) -> Void = { _ in }
    ) -> RLMGuileWorkerSession {
        var configuration = RLMGuileWorkerConfiguration(
            runID: runID,
            workerScriptPath: workerScriptPath,
            executablePath: guilePath ?? "/usr/bin/guile"
        )
        configure(&configuration)
        return RLMGuileWorkerSession(configuration: configuration, host: host, cancellation: cancellation)
    }

    static func plantSecret(_ name: String, value: String) {
        _ = setenv(name, value, 1)
    }
}

actor RLMGuileRecordingHost: RLMGuileHost {
    private var operations: [RLMHostOperation] = []
    private let cancellation: RLMCancellationToken?
    private let leafFailure: RLMFailure?
    private let blockingSeconds: Double
    private let oversizedChunkBytes: Int

    init(
        cancellation: RLMCancellationToken? = nil,
        leafFailure: RLMFailure? = nil,
        blockingSeconds: Double = 0,
        oversizedChunkBytes: Int = 0
    ) {
        self.cancellation = cancellation
        self.leafFailure = leafFailure
        self.blockingSeconds = blockingSeconds
        self.oversizedChunkBytes = oversizedChunkBytes
    }

    func service(_ operation: RLMHostOperation) async throws -> RLMHostObservation {
        operations.append(operation)
        cancellation?.cancel()
        if blockingSeconds > 0 {
            try? await Task.sleep(for: .seconds(blockingSeconds))
        }
        switch operation {
        case let .corpusSearch(query, limit):
            return .corpusSearch(
                hits: [
                    RLMSearchHit(
                        chunkID: "c-1",
                        path: "Sources/A.swift",
                        startLine: 1,
                        endLine: 2,
                        preview: "\(query) \(limit)",
                        score: 1
                    )
                ],
                bytesRead: 12
            )
        case let .corpusRead(chunkIDs):
            let chunks = chunkIDs.map { identifier in
                RLMCorpusChunk(
                    id: identifier,
                    path: "Sources/A.swift",
                    startLine: 1,
                    endLine: 2,
                    content: oversizedChunkBytes > 0
                        ? String(repeating: "x", count: oversizedChunkBytes)
                        : "content \(identifier)",
                    byteCount: 12,
                    digest: "digest"
                )
            }
            return .corpusRead(chunks: chunks, bytesRead: chunks.count * 12)
        case let .leafQuery(prompts, _):
            if let leafFailure {
                throw leafFailure
            }
            return .leaf(responses: prompts.map { "leaf:\($0)" }, estimatedTokens: prompts.count)
        case .progress:
            return .progress
        case .finish:
            throw RLMFailure.evaluatorFailed("finish must not be serviced as a host operation")
        }
    }

    func recorded() -> [RLMHostOperation] {
        operations
    }
}
