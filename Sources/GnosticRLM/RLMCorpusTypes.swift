// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// One accepted file in an immutable corpus snapshot.
public struct RLMCorpusFile: Sendable, Equatable {
    public let path: String
    public let byteCount: Int
    public let digest: String
    public let chunkIDs: [String]

    public init(path: String, byteCount: Int, digest: String, chunkIDs: [String]) {
        self.path = path
        self.byteCount = byteCount
        self.digest = digest
        self.chunkIDs = chunkIDs
    }
}

/// One addressable line range in an immutable corpus snapshot.
public struct RLMCorpusChunk: Sendable, Equatable {
    public let id: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let byteCount: Int
    public let digest: String

    public init(
        id: String,
        path: String,
        startLine: Int,
        endLine: Int,
        content: String,
        byteCount: Int,
        digest: String
    ) {
        self.id = id
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.byteCount = byteCount
        self.digest = digest
    }
}

/// Why a listed file did not become part of a snapshot.
public enum RLMSkipReason: Sendable, Equatable, CustomStringConvertible {
    case outsideAllowedPrefixes
    case binaryContent
    case invalidUTF8
    case tooLarge(limit: Int)

    public var description: String {
        switch self {
        case .outsideAllowedPrefixes:
            return "outside allowed path prefixes"
        case .binaryContent:
            return "binary content"
        case .invalidUTF8:
            return "invalid UTF-8"
        case let .tooLarge(limit):
            return "exceeds the per-file byte limit \(limit)"
        }
    }
}

/// One listed file that was structurally excluded from a snapshot.
public struct RLMSkippedFile: Sendable, Equatable {
    public let path: String
    public let reason: RLMSkipReason

    public init(path: String, reason: RLMSkipReason) {
        self.path = path
        self.reason = reason
    }
}

/// The bounded, non-content view of a snapshot handed to a root model.
public struct RLMCorpusMetadata: Sendable, Equatable {
    public let snapshotID: String
    public let revisionDigest: String
    public let fileCount: Int
    public let chunkCount: Int
    public let totalBytes: Int
    public let skippedFileCount: Int
    public let allowedPathPrefixes: [String]

    public init(
        snapshotID: String,
        revisionDigest: String,
        fileCount: Int,
        chunkCount: Int,
        totalBytes: Int,
        skippedFileCount: Int,
        allowedPathPrefixes: [String]
    ) {
        self.snapshotID = snapshotID
        self.revisionDigest = revisionDigest
        self.fileCount = fileCount
        self.chunkCount = chunkCount
        self.totalBytes = totalBytes
        self.skippedFileCount = skippedFileCount
        self.allowedPathPrefixes = allowedPathPrefixes
    }
}

/// An immutable, content-addressed capture of one Workspace corpus.
///
/// The snapshot is created before root execution begins. Every value is `let`,
/// and the only lookup structure is derived at construction, so no later host
/// or model action can change what the run may read or cite.
public struct RLMCorpusSnapshot: Sendable, Equatable {
    public let id: String
    public let workspaceID: String
    public let revisionDigest: String
    public let files: [RLMCorpusFile]
    public let chunks: [RLMCorpusChunk]
    public let skipped: [RLMSkippedFile]
    public let allowedPathPrefixes: [String]

    private let chunkIndex: [String: Int]

    public init(
        id: String,
        workspaceID: String,
        revisionDigest: String,
        files: [RLMCorpusFile],
        chunks: [RLMCorpusChunk],
        skipped: [RLMSkippedFile],
        allowedPathPrefixes: [String]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.revisionDigest = revisionDigest
        self.files = files
        self.chunks = chunks
        self.skipped = skipped
        self.allowedPathPrefixes = allowedPathPrefixes
        self.chunkIndex = Dictionary(uniqueKeysWithValues: chunks.enumerated().map { ($1.id, $0) })
    }

    public var totalBytes: Int {
        files.reduce(0) { $0 + $1.byteCount }
    }

    public var metadata: RLMCorpusMetadata {
        RLMCorpusMetadata(
            snapshotID: id,
            revisionDigest: revisionDigest,
            fileCount: files.count,
            chunkCount: chunks.count,
            totalBytes: totalBytes,
            skippedFileCount: skipped.count,
            allowedPathPrefixes: allowedPathPrefixes
        )
    }

    public func chunk(id: String) -> RLMCorpusChunk? {
        guard let index = chunkIndex[id] else { return nil }
        return chunks[index]
    }

    public func chunks(ids: [String]) -> [RLMCorpusChunk] {
        ids.compactMap { chunk(id: $0) }
    }
}
