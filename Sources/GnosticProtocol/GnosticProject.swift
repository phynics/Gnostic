// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A Project names the directory an ACP Runtime session starts in.
///
/// A Project is Gnostic-backed placement metadata. It is not a Workspace and it
/// is not a filesystem sandbox: the Runtime's own file and shell tools can reach
/// any path allowed to its operating-system user (ADR 0021).
public struct Project: Codable, Equatable, Hashable, Sendable {
    /// How Gnostic places the Project directory.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// An operator-selected directory on the Runtime's Node.
        case local
        /// A clean, Gnostic-managed directory created for one Session.
        case scratch
    }

    /// The placement kind.
    public let kind: Kind
    /// The absolute local directory for ``Kind/local``.
    ///
    /// A scratch Project has no stored path. Gnostic chooses its directory when
    /// it opens the Session so that a fresh Session never reuses another
    /// Session's scratch files.
    public let path: String?

    /// Creates a Project.
    ///
    /// - Parameters:
    ///   - kind: The placement kind.
    ///   - path: The absolute local directory, required for ``Kind/local``.
    public init(kind: Kind, path: String? = nil) {
        self.kind = kind
        self.path = path
    }

    /// Creates a Project at an operator-selected local directory.
    ///
    /// - Parameter path: The absolute local directory.
    /// - Returns: A local Project.
    public static func local(_ path: String) -> Self {
        .init(kind: .local, path: path)
    }

    /// A clean, Gnostic-managed scratch Project.
    public static let scratch = Self(kind: .scratch)

    /// The configured local path, when this is a local Project.
    public var localPath: String? {
        kind == .local ? path : nil
    }

    /// Validates the stored shape without touching the filesystem.
    ///
    /// Filesystem checks belong to ``ProjectDirectoryResolver`` because the
    /// directory exists on the Runtime's Node, not necessarily where the
    /// configuration is read.
    ///
    /// - Throws: ``ProjectValidationError`` when the shape is invalid.
    public func validate() throws {
        switch kind {
        case .local:
            guard let path,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectValidationError.localPathRequired
            }
            guard !path.contains("\0") else {
                throw ProjectValidationError.localPathContainsNull
            }
            guard path.hasPrefix("/") else {
                throw ProjectValidationError.localPathMustBeAbsolute(path)
            }
        case .scratch:
            guard path == nil else {
                throw ProjectValidationError.scratchPathNotAllowed
            }
        }
    }
}

/// Structural failures of a ``Project`` value.
public enum ProjectValidationError: Error, Equatable, Sendable, LocalizedError {
    /// A local Project has no path.
    case localPathRequired
    /// A local Project path contains a null character.
    case localPathContainsNull
    /// A local Project path is not absolute.
    case localPathMustBeAbsolute(String)
    /// A scratch Project carries a path, which would make it local-like.
    case scratchPathNotAllowed

    public var errorDescription: String? {
        switch self {
        case .localPathRequired:
            "A local Project requires an absolute directory path."
        case .localPathContainsNull:
            "A Project path cannot contain a null character."
        case let .localPathMustBeAbsolute(path):
            "The Project path '\(path)' must be absolute."
        case .scratchPathNotAllowed:
            "A scratch Project does not accept a path."
        }
    }
}
