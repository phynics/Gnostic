// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// The `gnostic-legacy` command-line tool.
///
/// This executable keeps the pre-firewall host composition, including the
/// bundled Positronic backend, until #611 deletes it. The shipped `gnostic`
/// tool is the clean one.
@main
struct GnosticLegacyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic-legacy",
        abstract: "Inspect Axoloty objects, configure MQTT and Positronic details, and expose ACP.",
        version: "0.5.0",
        subcommands: [ConfigCommand.self, InspectCommand.self, ServeCommand.self, ACPCommand.self, ExperimentCommand.self, DoctorCommand.self, TurnLogCommand.self]
    )
}
