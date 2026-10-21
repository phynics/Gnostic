// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// The `gnostic` command-line tool.
///
/// The shipped tool hosts only process-independent backends. The transitional
/// host composition that still knows the bundled Positronic backend ships as
/// the separate `gnostic-legacy` executable until #611 removes it.
@main
struct GnosticCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic",
        abstract: "Inspect Axoloty objects, configure MQTT and Ascendant details, and expose ACP.",
        version: "0.5.0",
        subcommands: [ConfigCommand.self, InspectCommand.self, ServeCommand.self, ACPCommand.self, ExperimentCommand.self, DoctorCommand.self, TurnLogCommand.self]
    )
}
