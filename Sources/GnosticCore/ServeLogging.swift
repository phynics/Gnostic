// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging
import PKUtilities

/// Stable logging subsystem for the Gnostic serve process.
///
/// All serve records share the `me.atkn.gnostic.serve` label so an operator can
/// filter the whole service from a mixed log stream and trace an operation
/// end-to-end. The logger is injectable so tests can capture records on an
/// in-memory `LogHandler`.
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

/// A trace-enriched record emitted by the serve runtime.
///
/// Records are deliberately small and machine-parseable: one per lifecycle event
/// or served operation, carrying the identifiers needed to trace a request
/// through the process.
public enum ServeTrace {
    // MARK: Lifecycle
    public static func startup(logger: Logger, host: String, port: Int, namespace: String, timelineID: UUID) {
        logger.info("serve startup", metadata: [
            "host": .string(host),
            "port": .stringConvertible(port),
            "namespace": .string(namespace),
            "timeline": .string(timelineID.uuidString.lowercased()),
        ])
    }

    public static func shutdown(logger: Logger) {
        logger.info("serve shutdown")
    }

    // MARK: Advertisement
    public static func advertised(logger: Logger, objects: Int, timelineID: UUID) {
        logger.info("advertised objects", metadata: [
            "objectCount": .stringConvertible(objects),
            "timeline": .string(timelineID.uuidString.lowercased()),
        ])
    }

    public static func readvertised(logger: Logger, reason: String, timelineID: UUID) {
        logger.debug("readvertised", metadata: [
            "reason": .string(reason),
            "timeline": .string(timelineID.uuidString.lowercased()),
        ])
    }

    // MARK: Operations
    public static func operationStarted(
        logger: Logger,
        operation: String,
        timelineID: UUID?,
        workspaceID: UUID?,
        clientTurnID: String? = nil
    ) {
        var metadata: Logger.Metadata = ["operation": .string(operation)]
        if let timelineID {
            metadata["timeline"] = .string(timelineID.uuidString.lowercased())
        }
        if let workspaceID {
            metadata["workspace"] = .string(workspaceID.uuidString.lowercased())
        }
        if let clientTurnID {
            metadata["clientTurnID"] = .string(clientTurnID)
        }
        logger.debug("operation started", metadata: metadata)
    }

    public static func operationSucceeded(
        logger: Logger,
        operation: String,
        timelineID: UUID?,
        workspaceID: UUID?,
        clientTurnID: String? = nil,
        replayed: Bool? = nil
    ) {
        var metadata: Logger.Metadata = ["operation": .string(operation), "result": .string("success")]
        if let timelineID {
            metadata["timeline"] = .string(timelineID.uuidString.lowercased())
        }
        if let workspaceID {
            metadata["workspace"] = .string(workspaceID.uuidString.lowercased())
        }
        if let clientTurnID {
            metadata["clientTurnID"] = .string(clientTurnID)
        }
        if let replayed {
            metadata["replayed"] = .stringConvertible(replayed)
        }
        logger.info("operation succeeded", metadata: metadata)
    }

    public static func operationDenied(
        logger: Logger, operation: String, timelineID: UUID?, workspaceID: UUID?, reason: String
    ) {
        var metadata: Logger.Metadata = ["operation": .string(operation), "result": .string("denied")]
        if let timelineID {
            metadata["timeline"] = .string(timelineID.uuidString.lowercased())
        }
        if let workspaceID {
            metadata["workspace"] = .string(workspaceID.uuidString.lowercased())
        }
        metadata["reason"] = .string(reason)
        logger.warning("operation denied", metadata: metadata)
    }

    public static func operationFailed(
        logger: Logger,
        operation: String,
        timelineID: UUID?,
        workspaceID: UUID?,
        error: String,
        clientTurnID: String? = nil,
        conflict: Bool? = nil
    ) {
        var metadata: Logger.Metadata = ["operation": .string(operation), "result": .string("error")]
        if let timelineID {
            metadata["timeline"] = .string(timelineID.uuidString.lowercased())
        }
        if let workspaceID {
            metadata["workspace"] = .string(workspaceID.uuidString.lowercased())
        }
        if let clientTurnID {
            metadata["clientTurnID"] = .string(clientTurnID)
        }
        if let conflict {
            metadata["conflict"] = .stringConvertible(conflict)
        }
        metadata["error"] = .string(error)
        logger.error("operation failed", metadata: metadata)
    }

    // MARK: Generic error
    public static func failure(logger: Logger, message: String, error: Error) {
        logger.error("\(message)", metadata: ["error": .string(String(describing: error))])
    }
}
