// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM
import GnosticRLMProcessWorker

/// Chibi Scheme 0.12, built with the reviewed flag set, as an RLM worker
/// executor.
///
/// Chibi has no `setrlimit` binding, so `prlimit` applies the CPU and
/// address-space limits before the interpreter starts, and `CHIBI_MAX_ALLOC`
/// caps the limited-malloc heap. The reviewed build is Linux-only.
public enum RLMChibiExecutor: RLMWorkerExecutor {
    public typealias Configuration = RLMChibiWorkerConfiguration

    public static var displayName: String { "Chibi" }

    public static var isSupportedOnCurrentPlatform: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    public static func launchSpec(for configuration: RLMChibiWorkerConfiguration) -> RLMWorkerLaunchSpec {
        var environment = configuration.environment
        environment["CHIBI_MAX_ALLOC"] = String(configuration.maxHeapBytes)
        return RLMWorkerLaunchSpec(
            requirements: [
                .executable(configuration.executablePath),
                .limitTool(configuration.limitExecutablePath),
                .workerScript(configuration.workerScriptPath),
            ],
            launchPath: configuration.limitExecutablePath,
            arguments: [
                "--cpu=\(configuration.maxCPUSeconds)",
                "--as=\(configuration.maxAddressSpaceBytes)",
                "--",
                configuration.executablePath,
                configuration.workerScriptPath,
                "--max-address-space", String(configuration.maxAddressSpaceBytes),
                "--max-cpu", String(configuration.maxCPUSeconds),
            ],
            environment: environment,
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

/// One disposable Chibi worker process.
public typealias RLMChibiWorkerSession = RLMProcessWorkerSession<RLMChibiExecutor>
/// Why a Chibi worker session could not start.
public typealias RLMChibiWorkerError = RLMWorkerError<RLMChibiExecutor>
public typealias RLMChibiEvaluationOutcome = RLMWorkerEvaluationOutcome
public typealias RLMChibiHost = RLMWorkerHost
public typealias RLMChibiClosureHost = RLMWorkerClosureHost
package typealias RLMChibiProcessSignals = RLMProcessSignals
