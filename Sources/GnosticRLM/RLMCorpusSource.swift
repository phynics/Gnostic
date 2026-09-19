// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Synchronization

/// One file advertised by a corpus source before its content is captured.
public struct RLMCorpusSourceFile: Sendable, Equatable {
    public let path: String
    public let byteCount: Int

    public init(path: String, byteCount: Int) {
        self.path = path
        self.byteCount = byteCount
    }
}

/// The raw bytes of one corpus source file.
public struct RLMCorpusFileContent: Sendable, Equatable {
    public let path: String
    public let bytes: [UInt8]

    public init(path: String, bytes: [UInt8]) {
        self.path = path
        self.bytes = bytes
    }
}

/// A read-only view of the corpus source that a snapshotter may capture.
///
/// The harness never receives a Workspace path it can open directly. A future
/// adapter maps the attached Workspace file service onto this seam.
public protocol RLMCorpusSource: Sendable {
    func listFiles() async throws -> [RLMCorpusSourceFile]
    func readFile(at path: String) async throws -> RLMCorpusFileContent
}

/// A deterministic in-memory corpus source for fixtures and focused tests.
public final class RLMInMemoryCorpusSource: RLMCorpusSource, Sendable {
    private let storage: Mutex<[String: [UInt8]]>

    public init(files: [String: [UInt8]] = [:]) {
        self.storage = Mutex(files)
    }

    public convenience init(textFiles: [String: String]) {
        self.init(files: textFiles.mapValues { Array($0.utf8) })
    }

    public func setFile(path: String, bytes: [UInt8]) {
        storage.withLock { $0[path] = bytes }
    }

    public func setFile(path: String, text: String) {
        setFile(path: path, bytes: Array(text.utf8))
    }

    public func removeAll() {
        storage.withLock { $0.removeAll() }
    }

    public func listFiles() async throws -> [RLMCorpusSourceFile] {
        let files = storage.withLock { $0 }
        return files.keys.sorted().map { path in
            RLMCorpusSourceFile(path: path, byteCount: files[path]?.count ?? 0)
        }
    }

    public func readFile(at path: String) async throws -> RLMCorpusFileContent {
        let bytes = storage.withLock { $0[path] }
        guard let bytes else {
            throw RLMFailure.corpusSourceFailed("missing file '\(path)'")
        }
        return RLMCorpusFileContent(path: path, bytes: bytes)
    }
}
