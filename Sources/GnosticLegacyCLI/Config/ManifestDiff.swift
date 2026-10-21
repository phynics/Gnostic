// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A redacted, line-oriented manifest diff for `config --dry-run` output.
///
/// The diff is computed over the redacted JSON rendering of the two manifests,
/// so a secret written by a previewed `set-secret` never appears in the output.
/// The same redaction rule as `config show` applies: any `secrets` dictionary
/// and any `password` field is replaced before the comparison.
public enum ManifestDiff {
    /// Renders a unified-style diff between two manifests.
    ///
    /// - Parameters:
    ///   - before: The manifest before the previewed mutation.
    ///   - after: The manifest the mutation would write.
    /// - Returns: A diff with `-`/`+` line markers, or a no-change notice.
    public static func render(before: NodeManifest, after: NodeManifest) -> String {
        let beforeLines = before.redactedDescription().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let afterLines = after.redactedDescription().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hunks = diff(beforeLines, afterLines)
        guard hunks.contains(where: { $0.kind != .context }) else {
            return "No changes."
        }
        var lines = ["--- manifest (redacted)", "+++ manifest (preview, redacted)"]
        for hunk in hunks {
            switch hunk.kind {
            case .context: lines.append("  \(hunk.text)")
            case .removed: lines.append("- \(hunk.text)")
            case .added: lines.append("+ \(hunk.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One diff line and its disposition.
    enum Hunk: Equatable {
        case context(String)
        case removed(String)
        case added(String)

        var kind: Kind {
            switch self {
            case .context: .context
            case .removed: .removed
            case .added: .added
            }
        }

        var text: String {
            switch self {
            case let .context(text), let .removed(text), let .added(text): text
            }
        }

        enum Kind: Equatable { case context, removed, added }
    }

    /// Computes a longest-common-subsequence line diff.
    ///
    /// The manifest is small, so the quadratic table is bounded and the output
    /// is deterministic.
    static func diff(_ before: [String], _ after: [String]) -> [Hunk] {
        let rows = before.count
        let columns = after.count
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        if rows > 0, columns > 0 {
            for row in stride(from: rows - 1, through: 0, by: -1) {
                for column in stride(from: columns - 1, through: 0, by: -1) {
                    table[row][column] = before[row] == after[column]
                        ? table[row + 1][column + 1] + 1
                        : max(table[row + 1][column], table[row][column + 1])
                }
            }
        }
        var hunks: [Hunk] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if before[row] == after[column] {
                hunks.append(.context(before[row]))
                row += 1
                column += 1
            } else if table[row + 1][column] >= table[row][column + 1] {
                hunks.append(.removed(before[row]))
                row += 1
            } else {
                hunks.append(.added(after[column]))
                column += 1
            }
        }
        while row < rows { hunks.append(.removed(before[row])); row += 1 }
        while column < columns { hunks.append(.added(after[column])); column += 1 }
        return hunks
    }
}
