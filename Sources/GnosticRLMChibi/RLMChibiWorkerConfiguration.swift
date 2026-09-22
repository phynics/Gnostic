// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticRLM

/// Host-owned configuration for one disposable Chibi worker.
///
/// Every limit is set by the host. No tool argument, generated cell, or model
/// response can enlarge one. This worker is experimental and is not enabled in
/// any production composition.
public struct RLMChibiWorkerConfiguration: Sendable, Equatable {
    public var executablePath: String
    public var limitExecutablePath: String
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
        executablePath: String = RLMChibiWorkerConfiguration.defaultExecutablePath,
        limitExecutablePath: String = RLMChibiWorkerConfiguration.defaultLimitExecutablePath,
        profile: String = RLMSchemeProfile.name,
        environment: [String: String] = RLMChibiWorkerConfiguration.scrubbedEnvironment,
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
        self.limitExecutablePath = limitExecutablePath
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
            ProcessInfo.processInfo.environment["GNOSTIC_CHIBI"],
            "/usr/local/bin/chibi-scheme",
        ]
        for candidate in candidates {
            guard let candidate, FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return "/usr/local/bin/chibi-scheme"
    }

    /// The Chibi worker script bundled with this executor.
    ///
    /// Resolving the script from the bundle is what makes a deployed binary
    /// independent of the current working directory. A `nil` result means the
    /// resource is missing from the build, which is a packaging fault rather
    /// than a runtime condition.
    public static var defaultWorkerScriptPath: String? {
        Bundle.module.url(forResource: "worker", withExtension: "scm")?.path
    }


    /// The host utility that applies the process CPU and address-space rlimits
    /// before the Chibi interpreter starts.
    public static var defaultLimitExecutablePath: String {
        let candidates = [
            ProcessInfo.processInfo.environment["GNOSTIC_PRLIMIT"],
            "/usr/bin/prlimit",
        ]
        for candidate in candidates {
            guard let candidate, FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return "/usr/bin/prlimit"
    }

    /// A cleared environment that carries no credentials and no unrelated
    /// host configuration.
    public static var scrubbedEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
        ]
    }
}
