// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

private struct ListingOnlySource: RLMCorpusSource {
    let entries: [RLMCorpusSourceFile]
    let contents: [String: [UInt8]]

    func listFiles() async throws -> [RLMCorpusSourceFile] {
        entries
    }

    func readFile(at path: String) async throws -> RLMCorpusFileContent {
        guard let bytes = contents[path] else {
            throw RLMFailure.corpusSourceFailed("missing file '\(path)'")
        }
        return RLMCorpusFileContent(path: path, bytes: bytes)
    }
}

@Suite("RLM corpus snapshot")
struct RLMCorpusSnapshotTests {
    @Test("captures a deterministic repository fixture")
    func repositoryFixture() async throws {
        let source = RLMFixtures.repositorySource()
        let snapshotter = RLMCorpusSnapshotter()
        let snapshot = try await snapshotter.capture(from: source, workspaceID: "ws-a", budget: .standard)

        #expect(snapshot.files.count == 6)
        #expect(!snapshot.chunks.isEmpty)
        #expect(snapshot.skipped.contains(RLMSkippedFile(path: "Assets/diagram.png", reason: .binaryContent)))
        #expect(snapshot.skipped.contains(RLMSkippedFile(path: "Sources/legacy/Broken.swift", reason: .invalidUTF8)))
        #expect(snapshot.totalBytes > 0)
        #expect(!snapshot.revisionDigest.isEmpty)
        #expect(snapshot.id.hasPrefix("s-"))
    }

    @Test("produces stable identities across captures")
    func stableIdentity() async throws {
        let snapshotter = RLMCorpusSnapshotter()
        let first = try await snapshotter.capture(from: RLMFixtures.repositorySource(), workspaceID: "ws-a", budget: .standard)
        let second = try await snapshotter.capture(from: RLMFixtures.repositorySource(), workspaceID: "ws-a", budget: .standard)

        #expect(first.id == second.id)
        #expect(first.revisionDigest == second.revisionDigest)
        #expect(first.chunks.map(\.id) == second.chunks.map(\.id))
    }

    @Test("becomes immutable before root execution")
    func immutableAfterCapture() async throws {
        let source = RLMFixtures.textSource()
        let snapshotter = RLMCorpusSnapshotter()
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxCorpusFiles: 10))
        let snapshot = try await snapshotter.capture(from: source, workspaceID: "ws-a", budget: budget)
        let originalChunk = try #require(snapshot.chunks.first)

        source.setFile(path: "Sources/A.swift", text: "mutated after capture")

        #expect(snapshot.chunk(id: originalChunk.id)?.content == originalChunk.content)
        let recaptured = try await snapshotter.capture(from: source, workspaceID: "ws-a", budget: budget)
        #expect(recaptured.revisionDigest != snapshot.revisionDigest)
    }

    @Test("rejects absolute paths and traversal")
    func rejectsUnsafeListing() async throws {
        let snapshotter = RLMCorpusSnapshotter()
        let absolute = ListingOnlySource(
            entries: [RLMCorpusSourceFile(path: "/etc/passwd", byteCount: 1)],
            contents: ["/etc/passwd": [0x41]]
        )
        await #expect(throws: RLMFailure.absolutePathRejected("/etc/passwd")) {
            try await snapshotter.capture(from: absolute, workspaceID: "ws-a", budget: .standard)
        }

        let traversal = ListingOnlySource(
            entries: [RLMCorpusSourceFile(path: "../escape", byteCount: 1)],
            contents: ["../escape": [0x41]]
        )
        await #expect(throws: RLMFailure.parentTraversalRejected("../escape")) {
            try await snapshotter.capture(from: traversal, workspaceID: "ws-a", budget: .standard)
        }
    }

    @Test("de-duplicates normalized paths")
    func deduplicatesPaths() async throws {
        let source = ListingOnlySource(
            entries: [
                RLMCorpusSourceFile(path: "Sources/A.swift", byteCount: 4),
                RLMCorpusSourceFile(path: "Sources//A.swift", byteCount: 4),
            ],
            contents: ["Sources/A.swift": Array("data".utf8)]
        )
        let snapshot = try await RLMCorpusSnapshotter().capture(from: source, workspaceID: "ws-a", budget: .standard)
        #expect(snapshot.files.count == 1)
    }

    @Test("enforces the file count limit")
    func fileCountLimit() async throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxCorpusFiles: 2))
        await #expect(throws: RLMFailure.tooManyFiles(limit: 2)) {
            try await RLMCorpusSnapshotter().capture(from: RLMFixtures.textSource(), workspaceID: "ws-a", budget: budget)
        }
    }

    @Test("enforces the total byte limit")
    func totalByteLimit() async throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxCorpusBytes: 8))
        await #expect(throws: RLMFailure.corpusTooLarge(limit: 8)) {
            try await RLMCorpusSnapshotter().capture(from: RLMFixtures.textSource(), workspaceID: "ws-a", budget: budget)
        }
    }

    @Test("skips files over the per-file byte limit")
    func perFileLimit() async throws {
        let budget = RLMRunBudget.standard.narrowed(by: RLMRunBudgetRequest(maxCorpusFileBytes: 8))
        let snapshot = try await RLMCorpusSnapshotter().capture(
            from: RLMFixtures.textSource(),
            workspaceID: "ws-a",
            budget: budget
        )
        #expect(snapshot.files.isEmpty)
        #expect(snapshot.skipped.allSatisfy { reason in
            if case .tooLarge = reason.reason { return true }
            return false
        })
        #expect(snapshot.skipped.count == 3)
    }

    @Test("skips files outside the allowed prefixes")
    func allowedPrefixes() async throws {
        let policy = RLMCorpusPolicy(allowedPathPrefixes: ["Sources"])
        let snapshot = try await RLMCorpusSnapshotter(policy: policy).capture(
            from: RLMFixtures.repositorySource(),
            workspaceID: "ws-a",
            budget: .standard
        )
        #expect(snapshot.files.allSatisfy { $0.path.hasPrefix("Sources/") })
        #expect(snapshot.skipped.contains(RLMSkippedFile(path: "README.md", reason: .outsideAllowedPrefixes)))
    }
}
