// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM
import GnosticRLMProcessWorker

/// Chibi Scheme 0.12, built with the reviewed flag set, as an RLM worker
/// executor.
///
/// Chibi has no `setrlimit` binding, so the host limit launcher applies CPU and
/// address-space limits before the interpreter starts, and `CHIBI_MAX_ALLOC`
/// caps the limited-malloc heap. The host sends `SIGUSR1` at the configured
/// per-cell time limit; the patched VM converts it to a recoverable Scheme
/// exception. Darwin enforces the CPU limit and records address-space limits as
/// unavailable; Linux enforces both process limits.
public enum RLMChibiExecutor: RLMWorkerExecutor {
    public typealias Configuration = RLMChibiWorkerConfiguration

    public static var displayName: String { "Chibi" }

    public static var isSupportedOnCurrentPlatform: Bool {
        #if os(Linux)
        true
        #elseif os(macOS)
        true
        #else
        false
        #endif
    }

    public static func launchSpec(for configuration: RLMChibiWorkerConfiguration) -> RLMWorkerLaunchSpec {
        var environment = configuration.environment
        environment["CHIBI_MAX_ALLOC"] = String(configuration.maxHeapBytes)
        var arguments = ["--cpu=\(configuration.maxCPUSeconds)"]
        #if os(Linux)
        arguments.append("--as=\(configuration.maxAddressSpaceBytes)")
        let reportedAddressSpace = String(configuration.maxAddressSpaceBytes)
        #else
        let reportedAddressSpace = "-1"
        #endif
        arguments += [
            "--",
            configuration.executablePath,
            configuration.workerScriptPath,
            "--max-address-space", reportedAddressSpace,
            "--max-cpu", String(configuration.maxCPUSeconds),
        ]
        for key in environment.keys.sorted() {
            arguments += ["--environment-key", key]
        }
        return RLMWorkerLaunchSpec(
            requirements: [
                .executable(configuration.executablePath),
                .limitTool(configuration.limitExecutablePath),
                .workerScript(configuration.workerScriptPath),
            ],
            launchPath: configuration.limitExecutablePath,
            arguments: arguments,
            environment: environment,
            runID: configuration.runID,
            profile: configuration.profile,
            maxHeapBytes: configuration.maxHeapBytes,
            maxOutputBytes: configuration.maxOutputBytes,
            cellTimeLimitSeconds: configuration.cellTimeLimitSeconds,
            cellAllocationLimitBytes: configuration.cellAllocationLimitBytes,
            cellTimeoutInterruptSignal: .user1,
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
