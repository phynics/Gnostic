// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM
import GnosticRLMProcessWorker

/// GNU Guile 3.0 as an RLM worker executor.
///
/// The host limit launcher applies CPU and, on Linux, address-space limits
/// before Guile starts. Guile bounds each cell's time and allocation itself.
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
        var arguments = ["--cpu=\(configuration.maxCPUSeconds)"]
        #if os(Linux)
        arguments.append("--as=\(configuration.maxAddressSpaceBytes)")
        #endif
        arguments += [
            "--",
            configuration.executablePath,
            "--no-auto-compile",
            "-s", configuration.workerScriptPath,
        ]
        return RLMWorkerLaunchSpec(
            requirements: [
                .executable(configuration.executablePath),
                .limitTool(configuration.limitExecutablePath),
                .workerScript(configuration.workerScriptPath),
            ],
            launchPath: configuration.limitExecutablePath,
            arguments: arguments,
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
