// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM
import GnosticRLMProcessWorker

/// GNU Guile 3.0 as an RLM worker executor.
///
/// Guile applies its own process limits: the worker script calls `setrlimit`
/// for address space and CPU from the arguments below, and bounds each cell's
/// time and allocation itself.
public enum RLMGuileExecutor: RLMWorkerExecutor {
    public typealias Configuration = RLMGuileWorkerConfiguration

    public static var displayName: String { "Guile" }

    public static var isSupportedOnCurrentPlatform: Bool {
        #if os(macOS) || os(Linux)
        true
        #else
        false
        #endif
    }

    public static func launchSpec(for configuration: RLMGuileWorkerConfiguration) -> RLMWorkerLaunchSpec {
        RLMWorkerLaunchSpec(
            requirements: [
                .executable(configuration.executablePath),
                .workerScript(configuration.workerScriptPath),
            ],
            launchPath: configuration.executablePath,
            arguments: [
                "--no-auto-compile",
                "-s", configuration.workerScriptPath,
                "--max-address-space", String(configuration.maxAddressSpaceBytes),
                "--max-cpu", String(configuration.maxCPUSeconds),
            ],
            environment: configuration.environment,
            runID: configuration.runID,
            profile: configuration.profile,
            maxHeapBytes: configuration.maxHeapBytes,
            maxOutputBytes: configuration.maxOutputBytes,
            cellTimeLimitSeconds: configuration.cellTimeLimitSeconds,
            cellAllocationLimitBytes: configuration.cellAllocationLimitBytes,
            wallDeadlineSeconds: configuration.wallDeadlineSeconds,
            terminationGraceSeconds: configuration.terminationGraceSeconds,
            startupDeadlineSeconds: configuration.startupDeadlineSeconds,
            validationLimits: configuration.validationLimits
        )
    }
}

/// One disposable Guile worker process.
public typealias RLMGuileWorkerSession = RLMProcessWorkerSession<RLMGuileExecutor>
/// Why a Guile worker session could not start.
public typealias RLMGuileWorkerError = RLMWorkerError<RLMGuileExecutor>
public typealias RLMGuileEvaluationOutcome = RLMWorkerEvaluationOutcome
public typealias RLMGuileHost = RLMWorkerHost
public typealias RLMGuileClosureHost = RLMWorkerClosureHost
package typealias RLMGuileProcessSignals = RLMProcessSignals
