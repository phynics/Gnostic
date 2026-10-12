// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

#if os(Linux)
import Glibc
#endif

/// Process-level samples of one worker: peak resident memory and cumulative CPU
/// time, read from `/proc` on Linux.
///
/// These are comparative smoke measurements, not a profiler (ADR 0012).
public struct RLMWorkerProcessSample: Sendable {
    public let rssBytes: Int?
    public let cpuMilliseconds: Double?

    public init(rssBytes: Int?, cpuMilliseconds: Double?) {
        self.rssBytes = rssBytes
        self.cpuMilliseconds = cpuMilliseconds
    }

    /// Samples the process. Returns empty fields when the identifier is missing,
    /// the platform has no `/proc`, or the process has already exited.
    public static func read(_ processID: Int32?) -> RLMWorkerProcessSample {
        guard let processID else { return RLMWorkerProcessSample(rssBytes: nil, cpuMilliseconds: nil) }
        #if os(Linux)
        let statusPath = "/proc/\(processID)/status"
        let statPath = "/proc/\(processID)/stat"
        let rss = (try? String(contentsOfFile: statusPath, encoding: .utf8))
            .flatMap { status in
                status.split(separator: "\n").first { $0.hasPrefix("VmHWM:") }
            }
            .flatMap { line -> Int? in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, let kilobytes = Int(parts[1]) else { return nil }
                return kilobytes * 1_024
            }
        let cpu = (try? String(contentsOfFile: statPath, encoding: .utf8)).flatMap { stat -> Double? in
            guard let close = stat.lastIndex(of: ")") else { return nil }
            let fields = stat[stat.index(after: close)...].split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 12, let user = Int64(fields[11]), let system = Int64(fields[12]) else { return nil }
            let ticks = sysconf(Int32(_SC_CLK_TCK))
            guard ticks > 0 else { return nil }
            return Double(user + system) * 1_000 / Double(ticks)
        }
        return RLMWorkerProcessSample(rssBytes: rss, cpuMilliseconds: cpu)
        #else
        return RLMWorkerProcessSample(rssBytes: nil, cpuMilliseconds: nil)
        #endif
    }

    /// The CPU time spent between two samples, floored at zero, or `nil` when
    /// either sample has no CPU reading.
    public static func cpuDelta(before: RLMWorkerProcessSample, after: RLMWorkerProcessSample) -> Double? {
        guard let before = before.cpuMilliseconds, let after = after.cpuMilliseconds else { return nil }
        return max(0, after - before)
    }
}

/// Shared measurement helpers for the RLM executables.
public enum RLMWorkerMeasurement {
    /// A `Duration` expressed in fractional milliseconds.
    public static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

/// The outcome of one cancellation probe: how long the cancel took to land.
public struct RLMCancellationMeasurement: Codable, Sendable {
    public let latencyMilliseconds: Double?
    public let outcome: String?

    public init(latencyMilliseconds: Double?, outcome: String?) {
        self.latencyMilliseconds = latencyMilliseconds
        self.outcome = outcome
    }
}

/// The operating system and CPU architecture a measurement ran on.
public struct RLMHostDescription: Codable, Sendable {
    public let operatingSystem: String
    public let architecture: String

    public init(operatingSystem: String, architecture: String) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static var current: RLMHostDescription {
        #if os(Linux)
        let operatingSystem = "linux"
        #elseif os(macOS)
        let operatingSystem = "macos"
        #else
        let operatingSystem = "other"
        #endif
        #if arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unknown"
        #endif
        return RLMHostDescription(operatingSystem: operatingSystem, architecture: architecture)
    }
}
