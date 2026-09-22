// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import GnosticRLM
import GnosticRLMChibi
import GnosticRLMGuile

#if os(Linux)

@Suite("RLM worker wire parity", .enabled(if: RLMWorkerWireParitySupport.isAvailable), .serialized)
struct RLMWorkerWireParityTests {
    @Test("Guile and Chibi produce the same value frame for one corpus fixture")
    func valueFrameMatches() async throws {
        // The pinned Chibi build disables ratios and complex values while
        // preserving exact integer arithmetic, so these expressions exercise
        // the shared wire contract deterministically in both workers.
        let source = """
        (let* (
            (hits (corpus-search "wire parity" 1))
            (chunks (corpus-read-many (list "c-1")))
            (numbers (list (/ 1.0 3.0)
                          (expt 2 100)
                          (sqrt -1)
                          (/ 1.0 0.0)
                          (- (/ 1.0 0.0) (/ 1.0 0.0))
                          (- (expt 2 63) 1)
                          (expt 2 63)
                          (- 0 (expt 2 63))
                          (- 0 (expt 2 63) 1))))
          (list hits chunks numbers
                (list (string->symbol "wire-parity")
                      (string->symbol "A_"))
                (cons 'head 'tail)))
        """

        let guileHost = RLMGuileClosureHost { operation in
            try RLMWorkerWireParitySupport.observation(for: operation)
        }
        let chibiHost = RLMChibiClosureHost { operation in
            try RLMWorkerWireParitySupport.observation(for: operation)
        }
        let guile = RLMWorkerWireParitySupport.guileSession(host: guileHost)
        let chibi = RLMWorkerWireParitySupport.chibiSession(host: chibiHost)
        try await guile.start()
        try await chibi.start()

        let guileOutcome = await guile.evaluate(source: source)
        let chibiOutcome = await chibi.evaluate(source: source)
        await guile.shutdown()
        await chibi.shutdown()
        guard case let .value(guileValue) = guileOutcome else {
            Issue.record("Guile did not return a value frame: \(guileOutcome)")
            return
        }
        guard case let .value(chibiValue) = chibiOutcome else {
            Issue.record("Chibi did not return a value frame: \(chibiOutcome)")
            return
        }
        if guileValue != chibiValue {
            Issue.record("wire values differ: Guile=\(guileValue?.written ?? "nil") Chibi=\(chibiValue?.written ?? "nil")")
        }
    }
}

private enum RLMWorkerWireParitySupport {
    static var guilePath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["GNOSTIC_GUILE"],
            "/usr/bin/guile",
            "/opt/homebrew/bin/guile",
            "/usr/local/bin/guile",
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static var chibiPath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["GNOSTIC_CHIBI"],
            "/usr/local/bin/chibi-scheme",
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static var scriptDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var guileScriptPath: String {
        scriptDirectory.appendingPathComponent("Experiments/GuileRLMWorker/worker.scm").path
    }

    static var chibiScriptPath: String {
        scriptDirectory.appendingPathComponent("Experiments/ChibiRLMWorker/worker.scm").path
    }

    static var isAvailable: Bool {
        guilePath != nil
            && chibiPath != nil
            && FileManager.default.fileExists(atPath: guileScriptPath)
            && FileManager.default.fileExists(atPath: chibiScriptPath)
    }

    static func guileSession(host: any RLMGuileHost) -> RLMGuileWorkerSession {
        RLMGuileWorkerSession(
            configuration: RLMGuileWorkerConfiguration(
                runID: "parity-guile",
                workerScriptPath: guileScriptPath,
                executablePath: guilePath ?? "/usr/bin/guile"
            ),
            host: host
        )
    }

    static func chibiSession(host: any RLMChibiHost) -> RLMChibiWorkerSession {
        RLMChibiWorkerSession(
            configuration: RLMChibiWorkerConfiguration(
                runID: "parity-chibi",
                workerScriptPath: chibiScriptPath,
                executablePath: chibiPath ?? "/usr/local/bin/chibi-scheme"
            ),
            host: host
        )
    }

    static func observation(for operation: RLMHostOperation) throws -> RLMHostObservation {
        switch operation {
        case let .corpusSearch(query, limit):
            return .corpusSearch(
                hits: [
                    RLMSearchHit(
                        chunkID: "c-1",
                        path: "Sources/Parity.swift",
                        startLine: 4,
                        endLine: 8,
                        preview: "\(query) \(limit)",
                        score: 1
                    ),
                ],
                bytesRead: 18
            )
        case let .corpusRead(chunkIDs):
            return .corpusRead(
                chunks: chunkIDs.map { identifier in
                    RLMCorpusChunk(
                        id: identifier,
                        path: "Sources/Parity.swift",
                        startLine: 4,
                        endLine: 8,
                        content: "same corpus \(identifier)",
                        byteCount: 18,
                        digest: "parity-digest"
                    )
                },
                bytesRead: chunkIDs.count * 18
            )
        case let .leafQuery(prompts, _):
            return .leaf(responses: prompts.map { "response:\($0)" }, estimatedTokens: prompts.count)
        case .progress:
            return .progress
        case .finish:
            throw RLMFailure.evaluatorFailed("finish must not be serviced as a host operation")
        }
    }
}

#endif
