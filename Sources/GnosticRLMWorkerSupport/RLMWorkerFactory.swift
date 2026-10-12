// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM
import GnosticRLMChibi
import GnosticRLMGuile
import GnosticRLMProcessWorker

/// A worker driver together with a way to read its process identifier for
/// measurement. Built by ``RLMWorkerFactory``.
public struct RLMWorkerDriverHandle: Sendable {
    /// The driver the evaluator and the cancellation path use.
    public let driver: any RLMWorkerDriver
    private let processIdentifierProvider: @Sendable () async -> Int32?

    init(
        driver: any RLMWorkerDriver,
        processIdentifierProvider: @escaping @Sendable () async -> Int32?
    ) {
        self.driver = driver
        self.processIdentifierProvider = processIdentifierProvider
    }

    /// The running worker's process identifier, or `nil` when it is not running.
    public var processIdentifier: Int32? {
        get async { await processIdentifierProvider() }
    }
}

/// The one executor-to-driver mapping for the RLM host, the scenario executable,
/// and the benchmark executable (ADR 0012).
///
/// The factory lives outside `GnosticRLM` so the harness module keeps no
/// executor dependency. It honours `GNOSTIC_GUILE_WORKER` and
/// `GNOSTIC_CHIBI_WORKER` as worker-script overrides for every caller, not only
/// the host.
public enum RLMWorkerFactory {
    /// Resolves the worker script for one selection.
    ///
    /// An existing environment override wins for development; otherwise the
    /// script bundled with the executor is used, so a deployed binary does not
    /// depend on its working directory.
    ///
    /// - Returns: The script path, or `nil` when neither an override nor the
    ///   bundled script is available.
    public static func scriptPath(
        for selection: RLMWorkerSelection,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let environmentKey = selection == .guile ? "GNOSTIC_GUILE_WORKER" : "GNOSTIC_CHIBI_WORKER"
        if let path = environment[environmentKey], FileManager.default.fileExists(atPath: path) {
            return path
        }
        switch selection {
        case .guile: return RLMGuileWorkerConfiguration.defaultWorkerScriptPath
        case .chibi: return RLMChibiWorkerConfiguration.defaultWorkerScriptPath
        }
    }

    /// Builds a driver for `selection`, failing when no worker script resolves.
    ///
    /// - Parameters:
    ///   - selection: The executor to run.
    ///   - runID: The run identifier the worker reports in its protocol frames.
    ///   - host: The host that services the worker's bounded host calls.
    /// - Throws: `RLMFailure.evaluatorFailed` when no worker script is available.
    public static func make(
        selection: RLMWorkerSelection,
        runID: String,
        host: any RLMWorkerHost
    ) throws -> any RLMWorkerDriver {
        try resolve(selection: selection, runID: runID, host: host).driver
    }

    /// Like ``make(selection:runID:host:)``, but also returns the process
    /// identifier reader that measurement needs.
    public static func resolve(
        selection: RLMWorkerSelection,
        runID: String,
        host: any RLMWorkerHost
    ) throws -> RLMWorkerDriverHandle {
        guard let workerScriptPath = scriptPath(for: selection) else {
            throw RLMFailure.evaluatorFailed("selected Scheme worker script is unavailable")
        }
        return makeHandle(
            selection: selection,
            runID: runID,
            host: host,
            workerScriptPath: workerScriptPath
        )
    }

    /// Builds a driver for `selection` with an explicit worker script.
    ///
    /// Callers that report an unavailable worker as a measurement, rather than
    /// as a thrown error, resolve the script themselves and pass it here. An
    /// empty path makes the worker fail at start, which those callers record.
    public static func makeHandle(
        selection: RLMWorkerSelection,
        runID: String,
        host: any RLMWorkerHost,
        workerScriptPath: String
    ) -> RLMWorkerDriverHandle {
        switch selection {
        case .guile:
            let configuration = RLMGuileWorkerConfiguration(
                runID: runID,
                workerScriptPath: workerScriptPath
            )
            return handle(
                RLMProcessWorkerDriver<RLMGuileExecutor>(
                    configuration: configuration,
                    host: host,
                    wallTimeLimit: .milliseconds(Int64(configuration.wallDeadlineSeconds * 1_000)),
                    outputLimitBytes: configuration.maxOutputBytes
                )
            )
        case .chibi:
            let configuration = RLMChibiWorkerConfiguration(
                runID: runID,
                workerScriptPath: workerScriptPath
            )
            return handle(
                RLMProcessWorkerDriver<RLMChibiExecutor>(
                    configuration: configuration,
                    host: host,
                    wallTimeLimit: .milliseconds(Int64(configuration.wallDeadlineSeconds * 1_000)),
                    outputLimitBytes: configuration.maxOutputBytes
                )
            )
        }
    }

    private static func handle<Executor: RLMWorkerExecutor>(
        _ driver: RLMProcessWorkerDriver<Executor>
    ) -> RLMWorkerDriverHandle {
        RLMWorkerDriverHandle(
            driver: driver,
            processIdentifierProvider: { await driver.processIdentifier }
        )
    }
}
