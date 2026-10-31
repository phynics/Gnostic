// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore
@testable import GnosticHost

/// Evidence for #677: a read-oriented local filesystem Workspace whose tools
/// cannot leave the configured root.
@Suite("Filesystem Workspace", .serialized)
@MainActor
struct FilesystemWorkspaceTests {
    nonisolated private static let secret = "TOP-SECRET-OUTSIDE-CONTENT"

    // MARK: - Fixture

    /// A temporary tree. `root` is the Workspace root; `outside` and
    /// `root-other` are siblings of it that no tool may reach.
    private struct Fixture {
        let base: URL
        let root: URL
        let outside: URL
        let sibling: URL

        init() throws {
            let fileManager = FileManager.default
            // Resolve the temp directory so that expectations hold when the
            // platform temp path is itself a symlink.
            let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            base = temp.appendingPathComponent("gnostic-fs-workspace-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("root", isDirectory: true)
            outside = base.appendingPathComponent("outside", isDirectory: true)
            sibling = base.appendingPathComponent("root-other", isDirectory: true)
            for directory in [root, outside, sibling] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try FilesystemWorkspaceTests.secret.write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
            try FilesystemWorkspaceTests.secret.write(to: sibling.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

            try "hello workspace".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
            try fileManager.createDirectory(at: root.appendingPathComponent("nested/deeper", isDirectory: true), withIntermediateDirectories: true)
            try "nested text".write(to: root.appendingPathComponent("nested/note.txt"), atomically: true, encoding: .utf8)

            // Symlinks: one that stays inside the root, and several that leave it.
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("alias.txt").path, withDestinationPath: "hello.txt")
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("link-to-outside-file").path, withDestinationPath: outside.appendingPathComponent("secret.txt").path)
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("link-to-outside-dir").path, withDestinationPath: outside.path)
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("relative-escape").path, withDestinationPath: "../outside")
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("sibling-link").path, withDestinationPath: "../root-other")
            try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("nested/deeper/up").path, withDestinationPath: "../../../outside")
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: base)
        }

        func write(_ data: Data, to name: String) throws {
            try data.write(to: root.appendingPathComponent(name))
        }
    }

    private func workspace(
        at uri: String,
        id: UUID = UUID()
    ) throws -> any LocalWorkspace {
        let configuration = NodeManifest.Workspace(id: id, name: "Files", uri: uri, kind: "filesystem")
        return try BackendComposition.default.makeAdapters().workspaces.makeWorkspace(for: configuration)
    }

    private func call(
        _ workspace: any LocalWorkspace,
        _ tool: String,
        _ arguments: [String: ManifestJSONValue]
    ) async throws -> BackendWorkspaceResult {
        try await workspace.executeTool(id: tool, parameters: arguments)
    }

    /// A failed result that discloses neither outside content nor any
    /// filesystem path of the test tree.
    private func expectContainedFailure(
        _ result: BackendWorkspaceResult,
        fixture: Fixture,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!result.isSuccess, sourceLocation: sourceLocation)
        let text = (result.message ?? "") + result.output
        #expect(!text.isEmpty, sourceLocation: sourceLocation)
        #expect(!text.contains(Self.secret), sourceLocation: sourceLocation)
        #expect(!text.contains(fixture.base.path), sourceLocation: sourceLocation)
        #expect(!text.contains("root-other"), sourceLocation: sourceLocation)
        #expect(!text.contains("/outside"), sourceLocation: sourceLocation)
    }

    // MARK: - Registration and metadata

    @Test("makeAdapters registers the filesystem kind without DEBUG-only code")
    func registeredInEveryBuild() throws {
        let kinds = BackendComposition.default.makeAdapters().workspaces.registeredKinds
        #expect(kinds == ["filesystem"])

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let composition = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/GnosticHost/BackendComposition.swift"),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/GnosticHost/FilesystemWorkspace.swift"),
            encoding: .utf8
        )
        #expect(!adapter.contains("#if DEBUG"))
        #expect(composition.contains("FilesystemWorkspace"))
        // The registration must sit outside every `#if DEBUG` block.
        var depth = 0
        for line in composition.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if DEBUG") { depth += 1 }
            else if trimmed.hasPrefix("#endif"), depth > 0 { depth -= 1 }
            else if depth > 0 { #expect(!trimmed.contains("FilesystemWorkspace")) }
        }
    }

    @Test("the Workspace advertises exactly two read tools with declared object schemas")
    func advertisesReadOnlyTools() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let id = UUID()
        let files = try workspace(at: fixture.root.path, id: id)
        let tools = try await files.listTools()
        #expect(Set(tools.map(\.id)) == ["list_directory", "read_file"])
        #expect(files.reference.tools == tools)
        #expect(files.reference.id == id)
        #expect(files.reference.uri == fixture.root.path)
        #expect(files.reference.status == .available)
        for tool in tools {
            guard case let .object(schema)? = tool.parametersSchema else {
                Issue.record("\(tool.id) declares no object schema")
                continue
            }
            #expect(schema["type"] == .string("object"))
            guard case let .object(properties)? = schema["properties"] else {
                Issue.record("\(tool.id) schema has no properties")
                continue
            }
            #expect(properties["path"] != nil)
        }
        guard case let .object(readSchema)? = tools.first(where: { $0.id == "read_file" })?.parametersSchema else {
            Issue.record("read_file schema missing"); return
        }
        #expect(readSchema["required"] == .array([.string("path")]))
    }

    // MARK: - Successful use

    @Test("lists a directory in sorted order with entry kinds")
    func listsDirectory() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "list_directory", ["path": .string("nested")])
        #expect(result.isSuccess)
        #expect(result.output == "directory deeper\nfile note.txt")
        // A symlink is listed as a symlink, without its target.
        let deeper = try await call(files, "list_directory", ["path": .string("nested/deeper")])
        #expect(deeper.output == "symlink up")
    }

    @Test("lists the root when the path is omitted or is a dot")
    func listsRoot() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        for arguments: [String: ManifestJSONValue] in [[:], ["path": .string(".")], ["path": .string("")], ["path": .string("./nested/..")]] {
            let result = try await call(files, "list_directory", arguments)
            if arguments["path"] == .string("./nested/..") {
                // `..` is rejected rather than normalized.
                #expect(!result.isSuccess)
                continue
            }
            #expect(result.isSuccess)
            #expect(result.output.contains("file hello.txt"))
            #expect(result.output.contains("directory nested"))
            #expect(result.output.contains("symlink alias.txt"))
        }
    }

    @Test("reads a text file inside the root, including through an in-root symlink")
    func readsTextFile() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        for path in ["hello.txt", "./hello.txt", "alias.txt", "nested//note.txt"] {
            let result = try await call(files, "read_file", ["path": .string(path)])
            #expect(result.isSuccess, "\(path)")
            if path.hasSuffix("note.txt") {
                #expect(result.output == "nested text")
            } else {
                #expect(result.output == "hello workspace")
            }
        }
    }

    @Test("accepts a file URL as the root")
    func fileURLRoot() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.absoluteString)
        let result = try await call(files, "read_file", ["path": .string("hello.txt")])
        #expect(result.output == "hello workspace")
    }

    @Test("reports a healthy Workspace until the root disappears")
    func health() throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        let health = try #require(files as? any LocalWorkspaceHealth)
        #expect(health.isHealthy)
        try FileManager.default.removeItem(at: fixture.root)
        #expect(!health.isHealthy)
    }

    // MARK: - Containment

    nonisolated static let escapingPaths = [
        "../outside/secret.txt",
        "../root-other/secret.txt",
        "nested/../../outside/secret.txt",
        "nested/deeper/../../../outside/secret.txt",
        "..",
        "/etc/passwd",
        "/",
        "link-to-outside-file",
        "link-to-outside-dir/secret.txt",
        "relative-escape/secret.txt",
        "sibling-link/secret.txt",
        "nested/deeper/up/secret.txt",
    ]

    @Test("read_file rejects every escape without leaking the target", arguments: escapingPaths)
    func readRejectsEscapes(path: String) async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "read_file", ["path": .string(path)])
        expectContainedFailure(result, fixture: fixture)
    }

    @Test("list_directory rejects every escape without leaking the target", arguments: [
        "..", "../outside", "../root-other", "/", "/etc",
        "link-to-outside-dir", "relative-escape", "sibling-link", "nested/deeper/up", "nested/../..",
    ])
    func listRejectsEscapes(path: String) async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "list_directory", ["path": .string(path)])
        expectContainedFailure(result, fixture: fixture)
    }

    @Test("a sibling directory that shares the root's name prefix is not inside the root")
    func rootPrefixMatchIsNotContainment() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        // `root-other` string-prefix-matches `root`; the symlink resolves there.
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "read_file", ["path": .string("sibling-link/secret.txt")])
        expectContainedFailure(result, fixture: fixture)
        // Absolute spelling of the sibling is rejected as well.
        let absolute = try await call(files, "read_file", ["path": .string(fixture.sibling.appendingPathComponent("secret.txt").path)])
        expectContainedFailure(absolute, fixture: fixture)
    }

    @Test("a root reached through a symlink still contains its tools")
    func rootGivenAsSymlink() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let rootLink = fixture.base.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(atPath: rootLink.path, withDestinationPath: "root")
        let files = try workspace(at: rootLink.path)
        let inside = try await call(files, "read_file", ["path": .string("hello.txt")])
        #expect(inside.output == "hello workspace")
        let escape = try await call(files, "read_file", ["path": .string("link-to-outside-file")])
        expectContainedFailure(escape, fixture: fixture)
    }

    // MARK: - Argument validation

    @Test("malformed arguments fail as tool results", arguments: [
        [String: ManifestJSONValue](),
        ["path": ManifestJSONValue.number(3)],
        ["path": .bool(true)],
        ["path": .null],
        ["path": .array([.string("hello.txt")])],
        ["path": .object(["a": .string("b")])],
        ["path": .string("hello.txt"), "extra": .string("x")],
        ["path": .string("hello\u{0}.txt")],
        ["path": .string("")],
    ])
    func readRejectsMalformedArguments(arguments: [String: ManifestJSONValue]) async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "read_file", arguments)
        expectContainedFailure(result, fixture: fixture)
    }

    @Test("list_directory rejects wrongly typed or unknown arguments", arguments: [
        ["path": ManifestJSONValue.number(3)],
        ["path": .null],
        ["path": .array([])],
        ["path": .string("."), "extra": .bool(true)],
        ["other": .string("x")],
        ["path": .string("nested\u{0}")],
    ])
    func listRejectsMalformedArguments(arguments: [String: ManifestJSONValue]) async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "list_directory", arguments)
        expectContainedFailure(result, fixture: fixture)
    }

    @Test("an unknown tool is rejected with a thrown error")
    func unknownTool() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        do {
            _ = try await files.executeTool(id: "write_file", parameters: ["path": .string("x"), "content": .string("y")])
            Issue.record("expected the unknown tool to be rejected")
        } catch {
            #expect(error as? FilesystemWorkspaceError == .unknownTool("write_file"))
        }
    }

    // MARK: - Content handling

    @Test("a missing file, a directory, and a non-text file fail as tool results")
    func unreadableAndNonText() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        try fixture.write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]), to: "image.bin")
        try fixture.write(Data([0x68, 0x69, 0xFF, 0xFE, 0x21]), to: "invalid-utf8.txt")
        let files = try workspace(at: fixture.root.path)
        for path in ["does-not-exist.txt", "nested", "image.bin", "invalid-utf8.txt"] {
            let result = try await call(files, "read_file", ["path": .string(path)])
            expectContainedFailure(result, fixture: fixture)
        }
        let notDirectory = try await call(files, "list_directory", ["path": .string("hello.txt")])
        expectContainedFailure(notDirectory, fixture: fixture)
        let missing = try await call(files, "list_directory", ["path": .string("nope")])
        expectContainedFailure(missing, fixture: fixture)
    }

    @Test("a file without read permission fails as a tool result", .enabled(if: geteuid() != 0))
    func permissionDenied() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let locked = fixture.root.appendingPathComponent("locked.txt")
        try "private".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "read_file", ["path": .string("locked.txt")])
        expectContainedFailure(result, fixture: fixture)
        #expect(!result.output.contains("private"))
    }

    @Test("an oversize file is truncated within the wire budget and says so")
    func oversizeFile() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        try fixture.write(Data(repeating: UInt8(ascii: "a"), count: 200_000), to: "big.txt")
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "read_file", ["path": .string("big.txt")])
        #expect(result.isSuccess)
        #expect(result.output.hasPrefix("aaaa"))
        #expect(result.output.contains("[truncated"))
        #expect(result.output.contains("200000"))
        try expectFitsWire(result)
    }

    @Test("truncation never splits a scalar and escaping cannot overflow the budget")
    func truncationIsScalarAndEscapeSafe() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        try fixture.write(Data(String(repeating: "é€𝄞", count: 3_000).utf8), to: "multibyte.txt")
        try fixture.write(Data(String(repeating: "\"/\\\n", count: 4_000).utf8), to: "escapes.txt")
        let files = try workspace(at: fixture.root.path)
        for name in ["multibyte.txt", "escapes.txt"] {
            let result = try await call(files, "read_file", ["path": .string(name)])
            #expect(result.isSuccess, "\(name)")
            #expect(result.output.contains("[truncated"), "\(name)")
            #expect(!result.output.contains("\u{FFFD}"), "\(name)")
            try expectFitsWire(result)
        }
    }

    @Test("a small file is returned whole with no truncation marker")
    func smallFileUntruncated() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "read_file", ["path": .string("hello.txt")])
        #expect(!result.output.contains("[truncated"))
    }

    @Test("a large directory listing is bounded and reports truncation")
    func largeDirectory() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let many = fixture.root.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<300 {
            _ = FileManager.default.createFile(atPath: many.appendingPathComponent(String(format: "entry-%04d.txt", index)).path, contents: nil)
        }
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "list_directory", ["path": .string("many")])
        #expect(result.isSuccess)
        #expect(result.output.hasPrefix("file entry-0000.txt"))
        #expect(result.output.contains("[truncated"))
        #expect(result.output.contains("300"))
        try expectFitsWire(result)
    }

    @Test("entry names with control characters cannot forge listing lines")
    func controlCharactersInNames() async throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        _ = FileManager.default.createFile(atPath: fixture.root.appendingPathComponent("a\nsymlink forged").path, contents: nil)
        let files = try workspace(at: fixture.root.path)
        let result = try await call(files, "list_directory", [:])
        #expect(result.isSuccess)
        #expect(!result.output.split(separator: "\n").contains { $0.hasPrefix("symlink forged") })
    }

    // MARK: - Configuration

    @Test("configuration fails clearly when the root is missing")
    func rootMustExist() throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let missing = fixture.base.appendingPathComponent("absent").path
        let id = UUID()
        #expect(throws: FilesystemWorkspaceError.rootNotFound(id)) { _ = try workspace(at: missing, id: id) }
    }

    @Test("configuration fails clearly when the root is a file")
    func rootMustBeDirectory() throws {
        let fixture = try Fixture(); defer { fixture.tearDown() }
        let id = UUID()
        #expect(throws: FilesystemWorkspaceError.rootNotDirectory(id)) {
            _ = try workspace(at: fixture.root.appendingPathComponent("hello.txt").path, id: id)
        }
    }

    @Test("configuration fails clearly when the URI is not an absolute path", arguments: [
        "relative/dir", "~/dir", "https://example.com/dir", "file://remote-host/dir", "file:relative", "",
    ])
    func rootMustBeAbsolute(uri: String) throws {
        let id = UUID()
        #expect(throws: FilesystemWorkspaceError.invalidRootURI(id)) { _ = try workspace(at: uri, id: id) }
    }

    @Test("configuration errors name the Workspace, not the path")
    func configurationErrorsDoNotEchoPaths() throws {
        let id = UUID()
        do {
            _ = try workspace(at: "/definitely/not/here-\(UUID().uuidString)", id: id)
            Issue.record("expected a configuration error")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains(id.uuidString))
            #expect(!text.contains("/definitely"))
        }
    }

    // MARK: - Helpers

    /// The serving side wraps a result in a JSON object before it checks the
    /// event budget; the encoded form must stay inside the embedded bound.
    private func expectFitsWire(
        _ result: BackendWorkspaceResult,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let object: [String: Any] = ["isSuccess": true, "output": result.output, "protocolMajor": 1]
        let encoded = try JSONSerialization.data(withJSONObject: object)
        #expect(encoded.count <= 1_400, "encoded result is \(encoded.count) bytes", sourceLocation: sourceLocation)
    }
}
