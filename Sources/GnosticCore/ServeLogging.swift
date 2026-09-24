// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging

/// Stable logging subsystem for the Gnostic serve process.
///
/// All serve records share the `me.atkn.gnostic.serve` label so an operator can
/// filter the whole service from a mixed log stream. The logger is injectable
/// so tests can capture records on an in-memory `LogHandler`.
public struct ServeLogging: Sendable {
    /// The subsystem label for all serve records.
    public static let subsystem = "me.atkn.gnostic.serve"

    /// Creates a serve logger.
    ///
    /// - Parameter label: Log label; defaults to the canonical subsystem.
    /// - Returns: A `Logging.Logger` bound to the serve subsystem.
    public static func makeLogger(label: String = subsystem) -> Logger {
        Logger(label: label)
    }
}

/// A trace-enriched record emitted by the serve process.
///
/// Records are deliberately small and machine-parseable and carry the
/// identifiers needed to trace an event through the process.
public enum ServeTrace {
    /// Records the initial advertisement of the served objects.
    public static func advertised(logger: Logger, objects: Int, timelineID: UUID) {
        logger.info("advertised objects", metadata: [
            "objectCount": .stringConvertible(objects),
            "timeline": .string(timelineID.uuidString.lowercased()),
        ])
    }
}
