// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// The `gnostic` command-line tool.
///
/// The host connects to Runtime processes through ACP v2 over stdio.
@main
struct GnosticCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic",
        abstract: "Inspect Axoloty objects, configure MQTT and Ascendant details, and expose ACP.",
        version: "0.5.0",
        subcommands: [ConfigCommand.self, InspectCommand.self, ServeCommand.self, ACPCommand.self, ExperimentCommand.self, DoctorCommand.self, TurnLogCommand.self]
    )
}
