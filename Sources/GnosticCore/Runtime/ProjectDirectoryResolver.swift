// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// A Project directory resolved on this Node.
public struct ResolvedProject: Equatable, Sendable {
    /// The placement kind this directory came from.
    public let kind: Project.Kind
    /// The absolute directory passed to ACP as the Session `cwd`.
    public let cwd: String
    /// The managed scratch root, present only for a scratch Project.
    public let scratchRoot: String?

    /// Creates a resolved Project directory.
    public init(kind: Project.Kind, cwd: String, scratchRoot: String? = nil) {
        self.kind = kind
        self.cwd = cwd
        self.scratchRoot = scratchRoot
    }

    /// Whether Gnostic owns and may later remove this directory.
    public var isManagedScratch: Bool {
        kind == .scratch && scratchRoot != nil
    }
}

/// Creates and validates Project directories on the Runtime's Node.
///
/// A local Project must already exist and must be an absolute directory.
/// A scratch Project is a new owner-only directory under a managed root. The
/// resolver never treats either placement as a sandbox (ADR 0021).
public struct ProjectDirectoryResolver: Sendable {
    /// The prefix of every Gnostic-managed scratch directory.
    public static let scratchDirectoryPrefix = "gnostic-scratch-"

    /// The root that holds scratch directories.
    public let scratchRoot: URL
    private let hasAbsoluteScratchRootPath: Bool

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - scratchRoot: An explicit scratch root, or `nil` to use
    ///     `GNOSTIC_SCRATCH_ROOT` when set, then the system temporary directory.
    ///   - environment: The environment used to resolve a default scratch root.
    ///   - temporaryDirectory: The system temporary directory.
    public init(
        scratchRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        if let scratchRoot {
            self.scratchRoot = scratchRoot
            hasAbsoluteScratchRootPath = scratchRoot.path.hasPrefix("/")
        } else if let configured = environment["GNOSTIC_SCRATCH_ROOT"], !configured.isEmpty {
            self.scratchRoot = URL(fileURLWithPath: configured, isDirectory: true)
            hasAbsoluteScratchRootPath = configured.hasPrefix("/")
        } else {
            self.scratchRoot = temporaryDirectory
            hasAbsoluteScratchRootPath = temporaryDirectory.path.hasPrefix("/")
        }
    }

    /// Resolves a configured Project to a usable absolute `cwd`.
    ///
    /// - Parameter project: The Project to resolve.
    /// - Returns: The resolved directory. A scratch Project always allocates a
    ///   new directory; callers that resume a Session reuse its stored `cwd`
    ///   instead of calling this again.
    /// - Throws: ``ProjectPlacementError`` when the Project is invalid or
    ///   cannot be created.
    public func resolve(_ project: Project) throws -> ResolvedProject {
        try project.validate()
        switch project.kind {
        case .local:
            let path = try validateLocalDirectory(project.path ?? "")
            return ResolvedProject(kind: .local, cwd: path)
        case .scratch:
            return try createScratchProject()
        }
    }

    /// Creates a clean scratch Project directory.
    ///
    /// The directory is named `gnostic-scratch-<uuid>` and has mode `0700`.
    ///
    /// - Returns: The new scratch directory.
    /// - Throws: ``ProjectPlacementError`` when the directory cannot be made.
    public func createScratchProject() throws -> ResolvedProject {
        let root = try ensureScratchRoot()
        let fileManager = FileManager.default
        for _ in 0..<8 {
            let directory = root.appendingPathComponent(
                Self.scratchDirectoryPrefix + UUID().uuidString.lowercased(),
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                return ResolvedProject(
                    kind: .scratch,
                    cwd: directory.standardizedFileURL.path,
                    scratchRoot: root.standardizedFileURL.path
                )
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw ProjectPlacementError.scratchCreationFailed(
                    path: directory.path,
                    reason: error.localizedDescription
                )
            }
        }
        throw ProjectPlacementError.scratchCreationFailed(
            path: root.path,
            reason: "Could not allocate a unique scratch directory."
        )
    }

    /// Removes a scratch Project Gnostic owns.
    ///
    /// A local Project is never removed. The path must be a direct child of the
    /// configured scratch root and carry the scratch prefix, so a stale or
    /// forged record cannot make Gnostic delete an arbitrary directory.
    ///
    /// - Parameter resolved: The Project directory to remove.
    /// - Throws: ``ProjectPlacementError`` when a managed scratch directory
    ///   cannot be removed.
    public func discard(_ resolved: ResolvedProject) throws {
        guard resolved.isManagedScratch else { return }
        let root = scratchRoot.standardizedFileURL.path
        let cwd = URL(fileURLWithPath: resolved.cwd).standardizedFileURL
        guard cwd.deletingLastPathComponent().path == root,
              cwd.lastPathComponent.hasPrefix(Self.scratchDirectoryPrefix) else {
            throw ProjectPlacementError.refusedToRemoveUnmanagedDirectory(resolved.cwd)
        }
        guard FileManager.default.fileExists(atPath: cwd.path) else { return }
        do {
            try FileManager.default.removeItem(at: cwd)
        } catch {
            throw ProjectPlacementError.scratchRemovalFailed(
                path: cwd.path,
                reason: error.localizedDescription
            )
        }
    }

    /// Returns whether a stored path is still a usable directory.
    ///
    /// - Parameter path: The absolute path to check.
    /// - Returns: `true` when the path names an existing directory.
    public func isUsableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Returns whether a path is a managed scratch directory under this root.
    ///
    /// - Parameter path: The absolute path to check.
    /// - Returns: `true` when the path is a direct scratch child.
    public func isManagedScratchDirectory(_ path: String) -> Bool {
        let root = scratchRoot.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        return candidate.deletingLastPathComponent().path == root
            && candidate.lastPathComponent.hasPrefix(Self.scratchDirectoryPrefix)
    }

    private func validateLocalDirectory(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ProjectPlacementError.localPathNotFound(url.path)
        }
        guard isDirectory.boolValue else {
            throw ProjectPlacementError.localPathNotDirectory(url.path)
        }
        return url.path
    }

    private func ensureScratchRoot() throws -> URL {
        guard hasAbsoluteScratchRootPath, !scratchRoot.path.contains("\0") else {
            throw ProjectPlacementError.scratchRootMustBeAbsolute(scratchRoot.path)
        }
        let root = scratchRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ProjectPlacementError.scratchRootNotDirectory(root.path)
            }
            return root
        }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            return root
        } catch {
            throw ProjectPlacementError.scratchCreationFailed(
                path: root.path,
                reason: error.localizedDescription
            )
        }
    }
}

/// Filesystem failures for Project placement.
public enum ProjectPlacementError: Error, Equatable, Sendable, LocalizedError {
    /// A local Project directory does not exist.
    case localPathNotFound(String)
    /// A local Project path names a file, not a directory.
    case localPathNotDirectory(String)
    /// The scratch root is not absolute.
    case scratchRootMustBeAbsolute(String)
    /// The scratch root exists but is not a directory.
    case scratchRootNotDirectory(String)
    /// A scratch directory or root could not be created.
    case scratchCreationFailed(path: String, reason: String)
    /// Gnostic refused to remove a directory it does not manage.
    case refusedToRemoveUnmanagedDirectory(String)
    /// A managed scratch directory could not be removed.
    case scratchRemovalFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .localPathNotFound(path):
            "The local Project directory '\(path)' does not exist."
        case let .localPathNotDirectory(path):
            "The local Project path '\(path)' is not a directory."
        case let .scratchRootMustBeAbsolute(path):
            "The scratch Project root '\(path)' must be absolute."
        case let .scratchRootNotDirectory(path):
            "The scratch Project root '\(path)' is not a directory."
        case let .scratchCreationFailed(path, reason):
            "Could not create the scratch Project at '\(path)': \(reason)"
        case let .refusedToRemoveUnmanagedDirectory(path):
            "Refused to remove the unmanaged directory '\(path)'."
        case let .scratchRemovalFailed(path, reason):
            "Could not remove the scratch Project at '\(path)': \(reason)"
        }
    }
}
