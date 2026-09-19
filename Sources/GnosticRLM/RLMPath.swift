// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Normalizes and validates corpus paths before they enter a snapshot.
public enum RLMPath {
    /// Returns the canonical relative form of `path`, or throws an `RLMFailure`.
    ///
    /// The normal form uses `/` separators, collapses `.` and empty components,
    /// and never begins with a separator. Absolute paths, drive-qualified paths,
    /// backslashes, NUL bytes, and `..` components are rejected.
    public static func normalize(_ path: String) throws -> String {
        if path.isEmpty {
            throw RLMFailure.invalidPath(path)
        }
        if path.utf8.contains(0) {
            throw RLMFailure.invalidPath(path)
        }
        if path.contains("\\") {
            throw RLMFailure.invalidPath(path)
        }
        if path.hasPrefix("/") || path.hasPrefix("~") {
            throw RLMFailure.absolutePathRejected(path)
        }
        if isDriveQualified(path) {
            throw RLMFailure.absolutePathRejected(path)
        }

        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                throw RLMFailure.parentTraversalRejected(path)
            }
            if component.contains(":") {
                throw RLMFailure.invalidPath(path)
            }
            components.append(String(component))
        }

        guard !components.isEmpty else {
            throw RLMFailure.invalidPath(path)
        }
        return components.joined(separator: "/")
    }

    /// Returns true when `path` equals a prefix or is contained by one.
    ///
    /// Both `path` and `prefixes` must already be normalized.
    public static func isWithin(_ path: String, prefixes: [String]) -> Bool {
        if prefixes.isEmpty {
            return true
        }
        return prefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private static func isDriveQualified(_ path: String) -> Bool {
        guard path.count >= 2 else { return false }
        let characters = Array(path)
        guard characters[1] == ":" else { return false }
        return characters[0].isLetter
    }
}
