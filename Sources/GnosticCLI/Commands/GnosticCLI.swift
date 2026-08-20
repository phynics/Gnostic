// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// The `gnostic` command-line tool.
@main
struct GnosticCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic",
        abstract: "Inspect Axoloty objects, configure MQTT and LLM details, and run Turns.",
        version: "0.2.0",
        subcommands: [ConfigCommand.self, InspectCommand.self, TurnCommand.self, ServeCommand.self, ACPCommand.self]
    )
}
