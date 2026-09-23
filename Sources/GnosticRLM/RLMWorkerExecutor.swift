// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// One Scheme runtime that can run as a disposable RLM worker process.
///
/// An executor states only what differs between runtimes: its display name,
/// the platforms its reviewed build supports, and how one configuration becomes
/// a launch. Process supervision, the framed protocol, cell validation, host
/// servicing and the cancellation and wall-time fences are shared and live in
/// `GnosticRLMProcessWorker`.
public protocol RLMWorkerExecutor: Sendable {
    /// The host-owned configuration for one worker of this executor.
    associatedtype Configuration: Sendable

    /// The runtime name used in diagnostics, for example `Guile`.
    static var displayName: String { get }

    /// Whether the reviewed build of this runtime supports the current platform.
    static var isSupportedOnCurrentPlatform: Bool { get }

    /// Resolves one configuration into the launch the shared session performs.
    static func launchSpec(for configuration: Configuration) -> RLMWorkerLaunchSpec
}

/// A worker signal used to interrupt a cell without terminating its process.
public enum RLMWorkerInterruptSignal: Sendable, Equatable {
    /// POSIX `SIGUSR1`; the Chibi build maps this to its VM interrupt flag.
    case user1
}

/// Everything the shared worker session needs to launch and bound one worker.
///
/// Every limit is set by the host. No tool argument, generated cell, or model
/// response can enlarge one.
public struct RLMWorkerLaunchSpec: Sendable, Equatable {
    /// A file that must be present before the worker is spawned.
    public enum Requirement: Sendable, Equatable {
        /// The runtime interpreter; must be an executable file.
        case executable(String)
        /// A host utility that applies process limits; must be an executable file.
        case limitTool(String)
        /// The worker script; must exist.
        case workerScript(String)
    }

    /// Checked in order before spawning; the first missing one is reported.
    public var requirements: [Requirement]
    /// The program the session spawns.
    public var launchPath: String
    public var arguments: [String]
    public var environment: [String: String]

    public var runID: String
    public var profile: String
    public var maxHeapBytes: Int
    public var maxOutputBytes: Int
    public var cellTimeLimitSeconds: Double
    public var cellAllocationLimitBytes: Int
    /// Optional cooperative process signal for recoverable per-cell timeout.
    public var cellTimeoutInterruptSignal: RLMWorkerInterruptSignal?
    public var wallDeadlineSeconds: Double
    public var terminationGraceSeconds: Double
    public var startupDeadlineSeconds: Double
    public var validationLimits: RLMSchemeProfile.Limits

    public init(
        requirements: [Requirement],
        launchPath: String,
        arguments: [String],
        environment: [String: String],
        runID: String,
        profile: String,
        maxHeapBytes: Int,
        maxOutputBytes: Int,
        cellTimeLimitSeconds: Double,
        cellAllocationLimitBytes: Int,
        cellTimeoutInterruptSignal: RLMWorkerInterruptSignal? = nil,
        wallDeadlineSeconds: Double,
        terminationGraceSeconds: Double,
        startupDeadlineSeconds: Double,
        validationLimits: RLMSchemeProfile.Limits
    ) {
        self.requirements = requirements
        self.launchPath = launchPath
        self.arguments = arguments
        self.environment = environment
        self.runID = runID
        self.profile = profile
        self.maxHeapBytes = maxHeapBytes
        self.maxOutputBytes = maxOutputBytes
        self.cellTimeLimitSeconds = cellTimeLimitSeconds
        self.cellAllocationLimitBytes = cellAllocationLimitBytes
        self.cellTimeoutInterruptSignal = cellTimeoutInterruptSignal
        self.wallDeadlineSeconds = wallDeadlineSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        self.startupDeadlineSeconds = startupDeadlineSeconds
        self.validationLimits = validationLimits
    }
}

/// Services the bounded host calls made by a running worker.
public protocol RLMWorkerHost: Sendable {
    func service(_ operation: RLMHostOperation) async throws -> RLMHostObservation
}

/// A closure-backed host used by focused tests and adapters.
public struct RLMWorkerClosureHost: RLMWorkerHost {
    private let handler: @Sendable (RLMHostOperation) async throws -> RLMHostObservation

    public init(handler: @escaping @Sendable (RLMHostOperation) async throws -> RLMHostObservation) {
        self.handler = handler
    }

    public func service(_ operation: RLMHostOperation) async throws -> RLMHostObservation {
        try await handler(operation)
    }
}

/// The terminal outcome of one worker evaluation.
public enum RLMWorkerEvaluationOutcome: Sendable, Equatable {
    case value(RLMSExpression?)
    case finished(answer: String, evidenceIDs: [String])
    case schemeFailed(String)
    case cellRejected(String)
    case timedOut
    case outputLimitReached
    case hostResultRejected(String)
    case cancelled
    case fenced
    case workerExited(Int32)
    case protocolViolation(String)
    case unsupportedPlatform
}

/// Why a worker session of one executor could not start.
///
/// Generic over the executor so each runtime keeps its own error type and its
/// own name in diagnostics, while the cases are defined once.
public enum RLMWorkerError<Executor: RLMWorkerExecutor>: Error, Sendable, Equatable, CustomStringConvertible {
    case executableMissing(String)
    /// Reported only by executors whose launch spec requires a limit tool.
    case limitToolMissing(String)
    case workerScriptMissing(String)
    case spawnFailed(String)
    case initializationFailed(String)
    case alreadyShutDown
    case unsupportedPlatform

    public var description: String {
        let name = Executor.displayName
        switch self {
        case let .executableMissing(path):
            return "\(name) executable not found at '\(path)'"
        case let .limitToolMissing(path):
            return "\(name) limit tool not found at '\(path)'"
        case let .workerScriptMissing(path):
            return "\(name) worker script not found at '\(path)'"
        case let .spawnFailed(message):
            return "\(name) worker failed to spawn: \(message)"
        case let .initializationFailed(message):
            return "\(name) worker failed to initialize: \(message)"
        case .alreadyShutDown:
            return "\(name) worker session is already shut down"
        case .unsupportedPlatform:
            return "the \(name) worker is not supported on this platform"
        }
    }
}
