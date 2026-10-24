// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// Keeps `gnostic experiment ...` as the public entry point while delegating
/// experiment code to the separately packaged consumer executable.
struct ExperimentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experiment",
        abstract: "Run opt-in evidence experiments outside a Node."
    )

    @Argument(parsing: .captureForPassthrough)
    var arguments: [String]

    func run() throws {
        guard let executable = ExperimentExecutableLocator.locate(
            executablePath: CommandLine.arguments.first ?? "",
            environment: ProcessInfo.processInfo.environment
        ) else {
            throw ValidationError(
                "the gnostic-experiment executable must be installed beside gnostic or on PATH"
            )
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["experiment"] + arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ExitCode(process.terminationStatus)
        }
    }
}

enum ExperimentExecutableLocator {
    static func locate(executablePath: String, environment: [String: String]) -> URL? {
        if let configured = environment["GNOSTIC_EXPERIMENT_EXECUTABLE"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let sibling = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent("gnostic-experiment")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("gnostic-experiment")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
