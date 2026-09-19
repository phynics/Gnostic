// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Host-owned corpus shaping that is independent of per-run budgets.
public struct RLMCorpusPolicy: Sendable, Equatable {
    /// When non-empty, only paths equal to or under a prefix are accepted.
    public var allowedPathPrefixes: [String]
    /// Maximum number of source lines in one chunk.
    public var chunkLineLimit: Int
    /// Target maximum UTF-8 byte count of one chunk before a line break is preferred.
    public var chunkByteLimit: Int

    public init(
        allowedPathPrefixes: [String] = [],
        chunkLineLimit: Int = 80,
        chunkByteLimit: Int = 8192
    ) {
        self.allowedPathPrefixes = allowedPathPrefixes
        self.chunkLineLimit = chunkLineLimit
        self.chunkByteLimit = chunkByteLimit
    }

    public static let standard = RLMCorpusPolicy()
}

/// Captures a bounded, immutable corpus snapshot from a read-only source.
public struct RLMCorpusSnapshotter: Sendable {
    public let policy: RLMCorpusPolicy

    public init(policy: RLMCorpusPolicy = .standard) {
        self.policy = policy
    }

    /// Captures the accepted corpus and commits it as an immutable snapshot.
    ///
    /// Paths are normalized and validated before any read. Unsafe paths fail the
    /// capture. Files outside the allowed prefixes, binary files, invalid UTF-8,
    /// and files over the per-file limit are skipped and recorded. File count,
    /// total accepted bytes, and per-file bytes are enforced against `budget`.
    public func capture(
        from source: any RLMCorpusSource,
        workspaceID: String,
        budget: RLMRunBudget
    ) async throws -> RLMCorpusSnapshot {
        let prefixValues = try policy.allowedPathPrefixes.map { try RLMPath.normalize($0) }

        let listed: [RLMCorpusSourceFile]
        do {
            listed = try await source.listFiles()
        } catch let failure as RLMFailure {
            throw failure
        } catch {
            throw RLMFailure.corpusSourceFailed(String(describing: error))
        }

        var accepted: [(path: String, byteCount: Int)] = []
        var skipped: [RLMSkippedFile] = []
        var seen = Set<String>()
        for entry in listed {
            let normalized: String
            do {
                normalized = try RLMPath.normalize(entry.path)
            } catch let failure as RLMFailure {
                throw failure
            } catch {
                throw RLMFailure.invalidPath(entry.path)
            }
            guard seen.insert(normalized).inserted else { continue }
            guard RLMPath.isWithin(normalized, prefixes: prefixValues) else {
                skipped.append(RLMSkippedFile(path: normalized, reason: .outsideAllowedPrefixes))
                continue
            }
            accepted.append((normalized, entry.byteCount))
        }

        accepted.sort { $0.path < $1.path }
        guard accepted.count <= budget.maxCorpusFiles else {
            throw RLMFailure.tooManyFiles(limit: budget.maxCorpusFiles)
        }

        var files: [RLMCorpusFile] = []
        var chunks: [RLMCorpusChunk] = []
        var totalBytes = 0
        for entry in accepted {
            if entry.byteCount > budget.maxCorpusFileBytes {
                skipped.append(RLMSkippedFile(path: entry.path, reason: .tooLarge(limit: budget.maxCorpusFileBytes)))
                continue
            }

            let content: RLMCorpusFileContent
            do {
                content = try await source.readFile(at: entry.path)
            } catch let failure as RLMFailure {
                throw failure
            } catch {
                throw RLMFailure.corpusSourceFailed(String(describing: error))
            }

            let bytes = content.bytes
            if bytes.count > budget.maxCorpusFileBytes {
                skipped.append(RLMSkippedFile(path: entry.path, reason: .tooLarge(limit: budget.maxCorpusFileBytes)))
                continue
            }
            if bytes.contains(0) {
                skipped.append(RLMSkippedFile(path: entry.path, reason: .binaryContent))
                continue
            }
            guard let text = RLMCorpusText.decodeUTF8(bytes) else {
                skipped.append(RLMSkippedFile(path: entry.path, reason: .invalidUTF8))
                continue
            }
            guard totalBytes + bytes.count <= budget.maxCorpusBytes else {
                throw RLMFailure.corpusTooLarge(limit: budget.maxCorpusBytes)
            }

            let fileChunks = RLMCorpusText.chunk(path: entry.path, text: text, policy: policy)
            files.append(
                RLMCorpusFile(
                    path: entry.path,
                    byteCount: bytes.count,
                    digest: RLMDigest.sha256Hex(bytes),
                    chunkIDs: fileChunks.map(\.id)
                )
            )
            chunks.append(contentsOf: fileChunks)
            totalBytes += bytes.count
        }

        let revisionDigest = RLMDigest.sha256Hex(
            files.map { "\($0.path)\u{1F}\($0.digest)" }.joined(separator: "\u{1E}")
        )
        let snapshotID = "s-" + String(RLMDigest.sha256Hex("\(workspaceID)\u{1F}\(revisionDigest)").prefix(16))
        return RLMCorpusSnapshot(
            id: snapshotID,
            workspaceID: workspaceID,
            revisionDigest: revisionDigest,
            files: files,
            chunks: chunks,
            skipped: skipped,
            allowedPathPrefixes: prefixValues
        )
    }
}

enum RLMCorpusText {
    static func decodeUTF8(_ bytes: [UInt8]) -> String? {
        let decoded = String(decoding: bytes, as: UTF8.self)
        return Array(decoded.utf8) == bytes ? decoded : nil
    }

    static func chunk(path: String, text: String, policy: RLMCorpusPolicy) -> [RLMCorpusChunk] {
        let lineLimit = Swift.max(policy.chunkLineLimit, 1)
        let byteLimit = Swift.max(policy.chunkByteLimit, 1)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }

        var chunks: [RLMCorpusChunk] = []
        var current: [String] = []
        var currentBytes = 0
        var startLine = 1

        func flush(endLine: Int) {
            guard !current.isEmpty else { return }
            let content = current.joined(separator: "\n")
            let bytes = Array(content.utf8)
            let digest = RLMDigest.sha256Hex(bytes)
            let identity = "\(path)\u{1F}\(startLine)\u{1F}\(endLine)\u{1F}\(digest)"
            chunks.append(
                RLMCorpusChunk(
                    id: "c-" + String(RLMDigest.sha256Hex(identity).prefix(16)),
                    path: path,
                    startLine: startLine,
                    endLine: endLine,
                    content: content,
                    byteCount: bytes.count,
                    digest: digest
                )
            )
            current.removeAll(keepingCapacity: true)
            currentBytes = 0
        }

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            if current.isEmpty {
                startLine = lineNumber
            }
            current.append(line)
            currentBytes += line.utf8.count + 1
            if current.count >= lineLimit || currentBytes >= byteLimit {
                flush(endLine: lineNumber)
            }
        }
        if !current.isEmpty {
            flush(endLine: startLine + current.count - 1)
        }
        return chunks
    }
}
