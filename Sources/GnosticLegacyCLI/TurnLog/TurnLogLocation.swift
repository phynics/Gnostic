// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Resolves the durable Turn log and derived state paths.
///
/// `gnostic serve` and `gnostic turn-log` share this type so the writer and the
/// read-only viewer resolve the same files. An explicit `--turn-log` names a
/// file and implies its parent directory as the state home. Otherwise
/// `GNOSTIC_STATE_HOME` opts in, and an unset state directory leaves the
/// process-scoped default in place.
struct TurnLogLocation: Sendable {
    /// The explicit `--turn-log` value, if the operator gave one.
    let turnLogPath: String?

    init(turnLogPath: String?) {
        self.turnLogPath = turnLogPath
    }

    /// The durable state directory used for derived state.
    func stateHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let turnLogPath, !turnLogPath.isEmpty {
            return URL(fileURLWithPath: turnLogPath).deletingLastPathComponent()
        }
        guard let stateHome = environment["GNOSTIC_STATE_HOME"], !stateHome.isEmpty else { return nil }
        return URL(fileURLWithPath: stateHome, isDirectory: true)
    }

    /// The durable Turn event log location, or `nil` when none is configured.
    func turnLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let turnLogPath, !turnLogPath.isEmpty {
            return URL(fileURLWithPath: turnLogPath)
        }
        return stateHome(environment: environment)?.appendingPathComponent("turn-events-v1.jsonl")
    }

    /// The per-Ascendant Timeline transcript directory under the state home.
    func timelineStoreDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        stateHome(environment: environment)?.appendingPathComponent("timelines", isDirectory: true)
    }
}
