// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM

/// Host-owned configuration for one disposable Guile worker.
///
/// Every limit is set by the host. No tool argument, generated cell, or model
/// response can enlarge one. This worker is experimental and is not enabled in
/// any production composition.
public struct RLMGuileWorkerConfiguration: Sendable, Equatable {
    public var executablePath: String
    public var workerScriptPath: String
    public var runID: String
    public var profile: String
    public var environment: [String: String]
    public var maxHeapBytes: Int
    public var maxAddressSpaceBytes: Int
    public var maxCPUSeconds: Int
    public var maxOutputBytes: Int
    public var cellTimeLimitSeconds: Double
    public var cellAllocationLimitBytes: Int
    public var wallDeadlineSeconds: Double
    public var terminationGraceSeconds: Double
    public var startupDeadlineSeconds: Double
    public var validationLimits: RLMSchemeProfile.Limits

    public init(
        runID: String,
        workerScriptPath: String,
        executablePath: String = RLMGuileWorkerConfiguration.defaultExecutablePath,
        profile: String = RLMSchemeProfile.name,
        environment: [String: String] = RLMGuileWorkerConfiguration.scrubbedEnvironment,
        maxHeapBytes: Int = 64 * 1_024 * 1_024,
        maxAddressSpaceBytes: Int = 256 * 1_024 * 1_024,
        maxCPUSeconds: Int = 30,
        maxOutputBytes: Int = 256 * 1_024,
        cellTimeLimitSeconds: Double = 0.25,
        cellAllocationLimitBytes: Int = 32 * 1_024 * 1_024,
        wallDeadlineSeconds: Double = 5,
        terminationGraceSeconds: Double = 0.5,
        startupDeadlineSeconds: Double = 5,
        validationLimits: RLMSchemeProfile.Limits = .standard
    ) {
        self.executablePath = executablePath
        self.workerScriptPath = workerScriptPath
        self.runID = runID
        self.profile = profile
        self.environment = environment
        self.maxHeapBytes = maxHeapBytes
        self.maxAddressSpaceBytes = maxAddressSpaceBytes
        self.maxCPUSeconds = maxCPUSeconds
        self.maxOutputBytes = maxOutputBytes
        self.cellTimeLimitSeconds = cellTimeLimitSeconds
        self.cellAllocationLimitBytes = cellAllocationLimitBytes
        self.wallDeadlineSeconds = wallDeadlineSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        self.startupDeadlineSeconds = startupDeadlineSeconds
        self.validationLimits = validationLimits
    }

    public static var defaultExecutablePath: String {
        let candidates = [
            ProcessInfo.processInfo.environment["GNOSTIC_GUILE"],
            "/usr/bin/guile",
            "/opt/homebrew/bin/guile",
            "/usr/local/bin/guile",
        ]
        for candidate in candidates {
            guard let candidate, FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return "/usr/bin/guile"
    }

    /// A cleared environment that carries no credentials and no unrelated
    /// host configuration.
    public static var scrubbedEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
            "GUILE_AUTO_COMPILE": "0",
        ]
    }
}

/// Services the bounded host calls made by a running worker.
public protocol RLMGuileHost: Sendable {
    func service(_ operation: RLMHostOperation) async throws -> RLMHostObservation
}

/// A closure-backed host used by focused tests and adapters.
public struct RLMGuileClosureHost: RLMGuileHost {
    private let handler: @Sendable (RLMHostOperation) async throws -> RLMHostObservation

    public init(handler: @escaping @Sendable (RLMHostOperation) async throws -> RLMHostObservation) {
        self.handler = handler
    }

    public func service(_ operation: RLMHostOperation) async throws -> RLMHostObservation {
        try await handler(operation)
    }
}

/// The terminal outcome of one worker evaluation.
public enum RLMGuileEvaluationOutcome: Sendable, Equatable {
    case value(RLMSExpression?)
    case finished(answer: String, evidenceIDs: [String])
    case schemeFailed(String)
    case cellRejected(String)
    case timedOut
    case outputLimitReached
    case cancelled
    case fenced
    case workerExited(Int32)
    case protocolViolation(String)
    case unsupportedPlatform
}

/// Why a worker session could not start.
public enum RLMGuileWorkerError: Error, Sendable, Equatable, CustomStringConvertible {
    case executableMissing(String)
    case workerScriptMissing(String)
    case spawnFailed(String)
    case initializationFailed(String)
    case alreadyShutDown
    case unsupportedPlatform

    public var description: String {
        switch self {
        case let .executableMissing(path):
            return "Guile executable not found at '\(path)'"
        case let .workerScriptMissing(path):
            return "Guile worker script not found at '\(path)'"
        case let .spawnFailed(message):
            return "Guile worker failed to spawn: \(message)"
        case let .initializationFailed(message):
            return "Guile worker failed to initialize: \(message)"
        case .alreadyShutDown:
            return "Guile worker session is already shut down"
        case .unsupportedPlatform:
            return "the Guile worker is not supported on this platform"
        }
    }
}
