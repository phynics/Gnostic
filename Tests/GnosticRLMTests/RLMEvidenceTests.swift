// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM evidence validation")
struct RLMEvidenceTests {
    private func makeSnapshot() async throws -> RLMCorpusSnapshot {
        try await RLMCorpusSnapshotter().capture(
            from: RLMFixtures.repositorySource(),
            workspaceID: "ws-a",
            budget: .standard
        )
    }

    private func reference(for chunk: RLMCorpusChunk) -> RLMEvidenceReference {
        RLMEvidenceReference(
            chunkID: chunk.id,
            path: chunk.path,
            startLine: chunk.startLine,
            endLine: chunk.endLine
        )
    }

    @Test("accepts references that belong to the snapshot")
    func acceptsValid() async throws {
        let snapshot = try await makeSnapshot()
        let chunk = try #require(snapshot.chunks.first)
        let accepted = try RLMEvidenceValidator.validate(
            [reference(for: chunk)],
            against: snapshot,
            limit: 8
        )
        #expect(accepted == [reference(for: chunk)])
    }

    @Test("rejects an unknown chunk")
    func rejectsUnknownChunk() async throws {
        let snapshot = try await makeSnapshot()
        let reference = RLMEvidenceReference(chunkID: "c-invented", path: "x", startLine: 1, endLine: 1)
        #expect(throws: RLMFailure.evidenceRejected(.unknownChunk("c-invented"))) {
            try RLMEvidenceValidator.validate([reference], against: snapshot, limit: 8)
        }
    }

    @Test("rejects a path that does not match the chunk")
    func rejectsPathMismatch() async throws {
        let snapshot = try await makeSnapshot()
        let chunk = try #require(snapshot.chunks.first)
        let reference = RLMEvidenceReference(
            chunkID: chunk.id,
            path: "forged/path.swift",
            startLine: chunk.startLine,
            endLine: chunk.endLine
        )
        #expect(throws: RLMFailure.evidenceRejected(
            .pathMismatch(chunkID: chunk.id, expected: chunk.path, actual: "forged/path.swift")
        )) {
            try RLMEvidenceValidator.validate([reference], against: snapshot, limit: 8)
        }
    }

    @Test("rejects an altered line range")
    func rejectsAlteredRange() async throws {
        let snapshot = try await makeSnapshot()
        let chunk = try #require(snapshot.chunks.first)
        let reference = RLMEvidenceReference(
            chunkID: chunk.id,
            path: chunk.path,
            startLine: chunk.startLine,
            endLine: chunk.endLine + 1
        )
        #expect(throws: RLMFailure.evidenceRejected(
            .lineRangeOutOfBounds(chunkID: chunk.id, startLine: chunk.startLine, endLine: chunk.endLine + 1)
        )) {
            try RLMEvidenceValidator.validate([reference], against: snapshot, limit: 8)
        }
    }

    @Test("rejects an inverted range")
    func rejectsInvertedRange() async throws {
        let snapshot = try await makeSnapshot()
        let chunk = try #require(snapshot.chunks.first(where: { $0.endLine > $0.startLine }))
        let reference = RLMEvidenceReference(
            chunkID: chunk.id,
            path: chunk.path,
            startLine: chunk.endLine,
            endLine: chunk.startLine
        )
        #expect(throws: RLMFailure.evidenceRejected(
            .invertedRange(chunkID: chunk.id, startLine: chunk.endLine, endLine: chunk.startLine)
        )) {
            try RLMEvidenceValidator.validate([reference], against: snapshot, limit: 8)
        }
    }

    @Test("de-duplicates repeated references")
    func deduplicates() async throws {
        let snapshot = try await makeSnapshot()
        let chunk = try #require(snapshot.chunks.first)
        let reference = reference(for: chunk)
        let accepted = try RLMEvidenceValidator.validate([reference, reference], against: snapshot, limit: 8)
        #expect(accepted == [reference])
    }

    @Test("rejects more references than the host allows")
    func rejectsTooMany() async throws {
        let snapshot = try await makeSnapshot()
        let chunks = Array(snapshot.chunks.prefix(2))
        let references = chunks.map { reference(for: $0) }
        #expect(throws: RLMFailure.evidenceRejected(.tooManyReferences(limit: 1))) {
            try RLMEvidenceValidator.validate(references, against: snapshot, limit: 1)
        }
    }
}
