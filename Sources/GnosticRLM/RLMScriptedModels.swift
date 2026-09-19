// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A deterministic root-model plan used by the Phase 0 harness.
///
/// Each step builds one cell from the observation history, so the generated
/// program always cites chunks that the committed snapshot actually contains.
public enum RLMRootPlanStep: Sendable, Equatable {
    case search(query: String, limit: Int)
    case readPreviousSearchHits(maxChunks: Int)
    case leafScan(tier: RLMLeafModelTier, instruction: String)
    case finish(answer: String)
    case invalid(reason: String)
}

/// A root model client that replays a fixed plan.
public actor ScriptedRootModel: RLMRootModelClient {
    private let plan: [RLMRootPlanStep]
    private var index = 0

    public init(plan: [RLMRootPlanStep]) {
        self.plan = plan
    }

    public func nextCell(request: RLMRootRequest) async throws -> RLMRootModelStep {
        guard index < plan.count else {
            return .invalid(reason: "root plan exhausted")
        }
        let step = plan[index]
        index += 1
        return Self.build(step, history: request.history)
    }

    static func build(_ step: RLMRootPlanStep, history: [RLMObservationRecord]) -> RLMRootModelStep {
        switch step {
        case let .search(query, limit):
            return .cell(RLMScriptedCell([.corpusSearch(query: query, limit: limit)]))
        case let .readPreviousSearchHits(maxChunks):
            let hits = mostRecentHits(in: history)
            let chunkIDs = Array(hits.prefix(max(0, maxChunks))).map(\.chunkID)
            guard !chunkIDs.isEmpty else {
                return .invalid(reason: "no search hits to read")
            }
            return .cell(RLMScriptedCell([.corpusRead(chunkIDs: chunkIDs)]))
        case let .leafScan(tier, instruction):
            let chunks = uniqueReadChunks(in: history)
            guard !chunks.isEmpty else {
                return .invalid(reason: "no read chunks to scan")
            }
            let prompts = chunks.map { chunk in
                "\(instruction)\n\n\(chunk.path):\(chunk.startLine)-\(chunk.endLine)\n\(chunk.content)"
            }
            return .cell(RLMScriptedCell([.leafQuery(prompts: prompts, tier: tier)]))
        case let .finish(answer):
            let evidence = uniqueReadChunks(in: history).map { chunk in
                RLMEvidenceReference(
                    chunkID: chunk.id,
                    path: chunk.path,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine
                )
            }
            return .cell(RLMScriptedCell([.finish(answer: answer, evidence: evidence)]))
        case let .invalid(reason):
            return .invalid(reason: reason)
        }
    }

    static func mostRecentHits(in history: [RLMObservationRecord]) -> [RLMSearchHit] {
        for record in history.reversed() {
            if case let .corpusSearch(hits, _) = record.observation {
                return hits
            }
        }
        return []
    }

    static func uniqueReadChunks(in history: [RLMObservationRecord]) -> [RLMCorpusChunk] {
        var seen = Set<String>()
        var chunks: [RLMCorpusChunk] = []
        for record in history {
            guard case let .corpusRead(readChunks, _) = record.observation else { continue }
            for chunk in readChunks where seen.insert(chunk.id).inserted {
                chunks.append(chunk)
            }
        }
        return chunks
    }
}

/// A leaf model client that replays fixed responses, optionally defaulting.
public actor ScriptedLeafModel: RLMLeafModelClient {
    public enum Response: Sendable, Equatable {
        case text(String)
        case failure(String)
    }

    private let responses: [Response]
    private let defaultResponse: String?
    private var index = 0

    public init(responses: [Response]) {
        self.responses = responses
        self.defaultResponse = nil
    }

    public init(defaultResponse: String) {
        self.responses = []
        self.defaultResponse = defaultResponse
    }

    public func query(prompts: [String], tier: RLMLeafModelTier) async throws -> [String] {
        var output: [String] = []
        for _ in prompts {
            if index < responses.count {
                let response = responses[index]
                index += 1
                switch response {
                case let .text(value):
                    output.append(value)
                case let .failure(message):
                    throw RLMFailure.leafModelFailed(message)
                }
            } else if let defaultResponse {
                output.append(defaultResponse)
            } else {
                throw RLMFailure.leafModelFailed("leaf script exhausted")
            }
        }
        return output
    }
}
