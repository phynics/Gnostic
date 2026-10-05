// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// gnostic doctor — diagnose a Node before or during startup.
///
/// The default run is fully offline: it reads the manifest, the compiled module
/// descriptors, and the local filesystem. `--online` adds opt-in network probes,
/// and `--check-provider` additionally probes provider endpoints.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose a Node's configuration and environment.",
        discussion: """
        Checks are offline by default: manifest validity, secrets presence, \
        Workspace paths, per-tier provider configuration, module requirements, \
        registry consistency, and executor prerequisites. Add `--online` for \
        broker reachability and protocol compatibility, and `--check-provider` \
        to probe provider endpoints. Secret values are never printed.

          gnostic doctor
          gnostic doctor --format json
          gnostic doctor --online
        """
    )

    @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
    var configPath: String?
    @Flag(name: .customLong("online"), help: "Run the opt-in network checks (broker reachability, protocol major).")
    var online = false
    @Flag(name: .customLong("check-provider"), help: "Probe configured provider endpoints. Implies --online and may cost money.")
    var checkProvider = false
    @OptionGroup var experiments: ExperimentsOptions
    @OptionGroup var formatOptions: OutputFormatOptions

    func run() async throws {
        let format = try formatOptions.resolved()
        let report = DoctorLogic.run(
            store: ConfigCommandLogic.store(for: configPath),
            registry: try experiments.registry(),
            options: DoctorOptions(online: online, checkProvider: checkProvider)
        )
        switch format {
        case .human:
            print(DoctorRender.render(report))
        case .json:
            print(try JSONOutput.encode(report))
        }
        if !report.healthy {
            throw ExitCode.failure
        }
    }
}

/// Human-readable rendering for `gnostic doctor`.
enum DoctorRender {
    static func render(_ report: DoctorReport) -> String {
        var lines: [String] = []
        for finding in report.findings {
            let marker: String
            switch finding.severity {
            case .ok: marker = "ok"
            case .warning: marker = "warn"
            case .error: marker = "fail"
            }
            var line = "[\(marker)] \(finding.check): \(finding.message)"
            if let path = finding.path { line += " (\(path))" }
            lines.append(line)
            if let hint = finding.hint, finding.severity != .ok {
                lines.append("       hint: \(hint)")
            }
        }
        let errors = report.count(.error)
        let warnings = report.count(.warning)
        lines.append("\(report.healthy ? "Healthy" : "Unhealthy"): \(errors) error(s), \(warnings) warning(s).")
        return lines.joined(separator: "\n")
    }
}
