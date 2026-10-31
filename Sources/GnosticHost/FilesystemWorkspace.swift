// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A configuration failure or protocol violation of the filesystem Workspace.
///
/// Messages name the Workspace or the tool, never a filesystem path.
enum FilesystemWorkspaceError: Error, Equatable, Sendable, LocalizedError {
    /// The manifest `uri` is not an absolute path or a local `file:` URL.
    case invalidRootURI(UUID)
    /// The configured root does not exist or cannot be resolved.
    case rootNotFound(UUID)
    /// The configured root exists but is not a directory.
    case rootNotDirectory(UUID)
    /// The invoked tool is not advertised by this Workspace.
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRootURI(id):
            "Filesystem Workspace \(id.uuidString) needs an absolute directory path or file URL as its uri."
        case let .rootNotFound(id):
            "The root directory of filesystem Workspace \(id.uuidString) does not exist."
        case let .rootNotDirectory(id):
            "The root of filesystem Workspace \(id.uuidString) is not a directory."
        case let .unknownTool(tool):
            "The filesystem Workspace has no tool '\(tool)'."
        }
    }

    var reasonCode: String {
        switch self {
        case .invalidRootURI: "filesystemWorkspaceInvalidRootURI"
        case .rootNotFound: "filesystemWorkspaceRootNotFound"
        case .rootNotDirectory: "filesystemWorkspaceRootNotDirectory"
        case .unknownTool: "filesystemWorkspaceUnknownTool"
        }
    }
}

/// A read-only local filesystem Workspace confined to one root directory.
///
/// The manifest entry has `kind` `"filesystem"` and a `uri` that names the
/// root: an absolute path or a `file:` URL. The root must exist and be a
/// directory when the Node starts.
///
/// The Workspace advertises two tools, `list_directory` and `read_file`. Both
/// take a Workspace-relative `path`. The gateway does not validate arguments
/// against the declared schema, so the adapter does.
///
/// Containment rests on three checks, applied to every call:
/// 1. A path that is absolute, or has a `..` component, is rejected before it
///    touches the filesystem.
/// 2. The path is resolved with `realpath`, which follows every symlink, and
///    the result must be the root or lie below it. The comparison is on whole
///    path components, so `/data/root-other` is not inside `/data/root`.
/// 3. The path is opened without following a final symlink, and the opened
///    descriptor's own path is checked against the root again. That closes the
///    window in which a directory is swapped for a symlink after step 2.
///
/// Results are bounded so that the encoded result fits the Gnostic wire
/// payload, and say so when they are cut.
@MainActor
final class FilesystemWorkspace: LocalWorkspace, LocalWorkspaceHealth {
    /// The manifest `workspaces[].kind` this adapter serves.
    nonisolated static let kind = "filesystem"

    nonisolated static let listToolID = "list_directory"
    nonisolated static let readToolID = "read_file"

    /// The most escaped-JSON bytes of tool output, trailer included. Chosen
    /// below ``GnosticWirePayload/maximumTurnResultTextBytes`` so that the
    /// serving side's result envelope stays inside the wire budget.
    private static let outputBudget = 1_200
    private static let trailerReserve = 96
    private static let bodyBudget = outputBudget - trailerReserve
    private static let maximumPathBytes = 1_024
    private static let maximumEnumeratedEntries = 4_096

    let reference: BackendWorkspaceReference
    private let root: String
    private let rootPrefix: String

    /// Registers the kind in a Workspace registry.
    nonisolated static func register(in registry: inout WorkspaceAdapterRegistry) {
        registry.registerProduct(kind: kind) { configuration in
            try FilesystemWorkspace(configuration: configuration)
        }
    }

    /// Creates the Workspace from its manifest entry.
    ///
    /// - Throws: ``FilesystemWorkspaceError`` when the root is missing, is not
    ///   an absolute path or `file:` URL, or is not a directory.
    init(configuration: NodeManifest.Workspace) throws {
        guard let path = Self.rootPath(from: configuration.uri) else {
            throw FilesystemWorkspaceError.invalidRootURI(configuration.id)
        }
        guard let resolved = Self.realPath(path) else {
            throw FilesystemWorkspaceError.rootNotFound(configuration.id)
        }
        var info = stat()
        guard stat(resolved, &info) == 0 else {
            throw FilesystemWorkspaceError.rootNotFound(configuration.id)
        }
        guard Self.isKind(info, S_IFDIR) else {
            throw FilesystemWorkspaceError.rootNotDirectory(configuration.id)
        }
        root = resolved
        rootPrefix = resolved == "/" ? "/" : resolved + "/"
        reference = BackendWorkspaceReference(
            id: configuration.id,
            uri: configuration.uri,
            status: .available,
            tools: Self.tools
        )
    }

    var isHealthy: Bool {
        var info = stat()
        return stat(root, &info) == 0 && Self.isKind(info, S_IFDIR)
    }

    func listTools() async throws -> [BackendWorkspaceTool] { Self.tools }

    func executeTool(id: String, parameters: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult {
        switch id {
        case Self.listToolID:
            switch Self.pathArgument(parameters, required: false) {
            case let .failure(failure): return .failure(failure.message)
            case let .success(path): return listDirectory(path)
            }
        case Self.readToolID:
            switch Self.pathArgument(parameters, required: true) {
            case let .failure(failure): return .failure(failure.message)
            case let .success(path): return readFile(path)
            }
        default:
            throw FilesystemWorkspaceError.unknownTool(id)
        }
    }

    // MARK: - Tool catalog

    private static var tools: [BackendWorkspaceTool] {
        func schema(pathDescription: String, required: Bool) -> ManifestJSONValue {
            var fields: [String: ManifestJSONValue] = [
                "type": .string("object"),
                "properties": .object(["path": .object([
                    "type": .string("string"),
                    "description": .string(pathDescription),
                ])]),
                "additionalProperties": .bool(false),
            ]
            if required { fields["required"] = .array([.string("path")]) }
            return .object(fields)
        }
        return [
            BackendWorkspaceTool(
                id: listToolID,
                name: "List directory",
                description: "List the entries of a directory in the Workspace, with their kind. Output is bounded and says when it is cut.",
                parametersSchema: schema(
                    pathDescription: "Workspace-relative directory path. Omit or use '.' for the Workspace root.",
                    required: false
                ),
                requiresPermission: true
            ),
            BackendWorkspaceTool(
                id: readToolID,
                name: "Read file",
                description: "Read a UTF-8 text file in the Workspace. Output is bounded and says when it is cut.",
                parametersSchema: schema(pathDescription: "Workspace-relative file path.", required: true),
                requiresPermission: true
            ),
        ]
    }

    // MARK: - Arguments

    private static func pathArgument(
        _ parameters: [String: ManifestJSONValue],
        required: Bool
    ) -> Result<String, ToolFailure> {
        guard parameters.keys.allSatisfy({ $0 == "path" }) else {
            return .failure(ToolFailure("Only the 'path' argument is accepted."))
        }
        guard let value = parameters["path"] else {
            return required ? .failure(ToolFailure("The 'path' argument is required.")) : .success("")
        }
        guard case let .string(path) = value else {
            return .failure(ToolFailure("The 'path' argument must be a string."))
        }
        if required, path.isEmpty { return .failure(ToolFailure("The 'path' argument must not be empty.")) }
        return .success(path)
    }

    // MARK: - Tools

    private func listDirectory(_ relative: String) -> BackendWorkspaceResult {
        let resolved: String
        switch resolve(relative) {
        case let .failure(failure): return .failure(failure.message)
        case let .success(path): resolved = path
        }
        guard let descriptor = openContained(resolved, directory: true) else {
            return .failure("The path is not a readable directory in the Workspace.")
        }
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            return .failure("The directory could not be read.")
        }
        defer { closedir(stream) } // Closes the descriptor.

        var entries: [(name: String, kind: String)] = []
        var enumerationCapped = false
        let directoryDescriptor = dirfd(stream)
        while let entry = readdir(stream) {
            let name = Self.name(of: entry)
            if name == "." || name == ".." { continue }
            if entries.count >= Self.maximumEnumeratedEntries { enumerationCapped = true; break }
            var info = stat()
            let kind: String
            if fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { kind = "other" }
            else if Self.isKind(info, S_IFDIR) { kind = "directory" }
            else if Self.isKind(info, S_IFREG) { kind = "file" }
            else if Self.isKind(info, S_IFLNK) { kind = "symlink" }
            else { kind = "other" }
            entries.append((Self.display(name), kind))
        }
        entries.sort { ($0.name, $0.kind) < ($1.name, $1.kind) }

        var lines: [String] = []
        var spent = 0
        for entry in entries {
            let line = "\(entry.kind) \(entry.name)"
            let cost = Self.escapedCost(of: line) + Self.escapedCost(of: "\n")
            if spent + cost > Self.bodyBudget { break }
            spent += cost
            lines.append(line)
        }
        var output = lines.isEmpty && entries.isEmpty ? "(empty)" : lines.joined(separator: "\n")
        if lines.count < entries.count || enumerationCapped {
            let total = enumerationCapped ? "at least \(entries.count)" : "\(entries.count)"
            output += "\n[truncated: showing \(lines.count) of \(total) entries]"
        }
        return BackendWorkspaceResult(value: .string(output))
    }

    private func readFile(_ relative: String) -> BackendWorkspaceResult {
        guard !relative.hasSuffix("/") else {
            return .failure("The path is not a regular file.")
        }
        let resolved: String
        switch resolve(relative) {
        case let .failure(failure): return .failure(failure.message)
        case let .success(path): resolved = path
        }
        guard let descriptor = openContained(resolved, directory: false) else {
            return .failure("The file could not be opened in the Workspace.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.isKind(info, S_IFREG) else {
            return .failure("The path is not a regular file.")
        }

        // Escaping only ever shrinks what fits, so the budget plus one UTF-8
        // scalar of slack is the most that can be shown.
        let readLimit = Self.bodyBudget + 4
        var buffer = [UInt8](repeating: 0, count: readLimit)
        var count = 0
        while count < readLimit {
            let received = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress!.advanced(by: count), readLimit - count)
            }
            if received == 0 { break }
            if received < 0 {
                if errno == EINTR { continue }
                return .failure("The file could not be read.")
            }
            count += received
        }
        // A concurrent append can outgrow the size read before the bytes were.
        let size = max(Int(info.st_size), count)
        let fileTruncated = size > count
        var bytes = Array(buffer[..<count])
        if bytes.contains(0) { return .failure("The file is not UTF-8 text.") }

        // A cut may land inside a scalar; shed up to three bytes before
        // deciding that the content is not text.
        var text = String(validating: bytes, as: UTF8.self)
        var shed = 0
        while text == nil, fileTruncated, shed < 3, !bytes.isEmpty {
            bytes.removeLast()
            shed += 1
            text = String(validating: bytes, as: UTF8.self)
        }
        guard let text else { return .failure("The file is not UTF-8 text.") }

        let (kept, clipped) = Self.clip(text, budget: Self.bodyBudget)
        guard fileTruncated || clipped else { return BackendWorkspaceResult(value: .string(kept)) }
        let output = kept + "\n[truncated: showing the first \(kept.utf8.count) of \(size) bytes]"
        return BackendWorkspaceResult(value: .string(output))
    }

    // MARK: - Containment

    private struct ToolFailure: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Resolves a Workspace-relative path to a real path inside the root.
    private func resolve(_ relative: String) -> Result<String, ToolFailure> {
        guard relative.utf8.count <= Self.maximumPathBytes, !relative.utf8.contains(0) else {
            return .failure(ToolFailure("The path is not valid."))
        }
        let notWithin = ToolFailure("The path is not within the Workspace.")
        if relative.hasPrefix("/") { return .failure(notWithin) }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") { return .failure(notWithin) }
        let kept = components.filter { $0 != "." }
        let candidate = kept.isEmpty ? root : rootPrefix + kept.joined(separator: "/")
        guard let resolved = Self.realPath(candidate) else {
            return .failure(ToolFailure("The path was not found or cannot be accessed."))
        }
        guard contains(resolved) else { return .failure(notWithin) }
        return .success(resolved)
    }

    private func contains(_ resolved: String) -> Bool {
        resolved == root || resolved.hasPrefix(rootPrefix)
    }

    /// Opens an already-resolved path without following a final symlink, then
    /// checks where the descriptor really points.
    private func openContained(_ resolved: String, directory: Bool) -> Int32? {
        var flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        if directory { flags |= O_DIRECTORY }
        let descriptor = open(resolved, flags)
        guard descriptor >= 0 else { return nil }
        guard let actual = Self.descriptorPath(descriptor), contains(actual) else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func descriptorPath(_ descriptor: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink("/proc/self/fd/\(descriptor)", &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func rootPath(from uri: String) -> String? {
        guard !uri.isEmpty, !uri.utf8.contains(0) else { return nil }
        if uri.hasPrefix("file:") {
            guard let url = URL(string: uri), url.scheme == "file",
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/") else { return nil }
            return url.path
        }
        guard !uri.contains("://"), uri.hasPrefix("/") else { return nil }
        return uri
    }

    private static func isKind(_ info: stat, _ kind: mode_t) -> Bool {
        info.st_mode & S_IFMT == kind
    }

    // MARK: - Output bounds

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
        }
    }

    /// Replaces control characters so a file name cannot forge a listing line.
    private static func display(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F ? "?" : scalar
        }))
    }

    /// The bytes a scalar takes once the serving side wraps the output in a
    /// JSON string.
    private static func escapedCost(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x22, 0x2F, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: 2
        case 0..<0x20: 6
        default: UTF8.width(scalar)
        }
    }

    private static func escapedCost(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + escapedCost(of: $1) }
    }

    /// Keeps the longest prefix, cut on a scalar boundary, whose escaped size
    /// fits the budget.
    private static func clip(_ text: String, budget: Int) -> (kept: String, clipped: Bool) {
        var spent = 0
        var end = text.unicodeScalars.startIndex
        while end < text.unicodeScalars.endIndex {
            let cost = escapedCost(of: text.unicodeScalars[end])
            if spent + cost > budget { return (String(text.unicodeScalars[..<end]), true) }
            spent += cost
            end = text.unicodeScalars.index(after: end)
        }
        return (text, false)
    }
}
