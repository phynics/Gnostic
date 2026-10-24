// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser

/// The experiment consumer executable is packaged separately from the host.
@main
struct GnosticExperimentCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic-experiment",
        abstract: "Run isolated Gnostic experiment tools.",
        subcommands: [ExperimentCommand.self]
    )
}
