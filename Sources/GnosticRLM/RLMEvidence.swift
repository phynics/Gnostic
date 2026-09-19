// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A source reference returned by a run and validated against its snapshot.
public struct RLMEvidenceReference: Sendable, Equatable, Hashable {
    public let chunkID: String
    public let path: String
    public let startLine: Int
    public let endLine: Int

    public init(chunkID: String, path: String, startLine: Int, endLine: Int) {
        self.chunkID = chunkID
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }
}

/// Validates every returned evidence reference against the committed snapshot.
public enum RLMEvidenceValidator {
    /// Returns the accepted, de-duplicated references in first-seen order.
    ///
    /// Throws `RLMFailure.evidenceRejected` for an unknown chunk, a path that
    /// does not match the chunk, an inverted or out-of-bounds line range, or
    /// more references than the host allows.
    public static func validate(
        _ references: [RLMEvidenceReference],
        against snapshot: RLMCorpusSnapshot,
        limit: Int
    ) throws -> [RLMEvidenceReference] {
        guard references.count <= limit else {
            throw RLMFailure.evidenceRejected(.tooManyReferences(limit: limit))
        }
        var seen = Set<RLMEvidenceReference>()
        var accepted: [RLMEvidenceReference] = []
        for reference in references {
            guard let chunk = snapshot.chunk(id: reference.chunkID) else {
                throw RLMFailure.evidenceRejected(.unknownChunk(reference.chunkID))
            }
            guard reference.path == chunk.path else {
                throw RLMFailure.evidenceRejected(
                    .pathMismatch(
                        chunkID: reference.chunkID,
                        expected: chunk.path,
                        actual: reference.path
                    )
                )
            }
            guard reference.startLine <= reference.endLine else {
                throw RLMFailure.evidenceRejected(
                    .invertedRange(
                        chunkID: reference.chunkID,
                        startLine: reference.startLine,
                        endLine: reference.endLine
                    )
                )
            }
            guard reference.startLine >= chunk.startLine, reference.endLine <= chunk.endLine else {
                throw RLMFailure.evidenceRejected(
                    .lineRangeOutOfBounds(
                        chunkID: reference.chunkID,
                        startLine: reference.startLine,
                        endLine: reference.endLine
                    )
                )
            }
            if seen.insert(reference).inserted {
                accepted.append(reference)
            }
        }
        return accepted
    }
}
