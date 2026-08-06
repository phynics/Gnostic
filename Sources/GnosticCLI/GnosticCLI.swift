// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// The `gnostic` command-line tool.
@main
struct GnosticCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gnostic",
        abstract: "Inspect Axoloty objects, configure MQTT and LLM details, and chat.",
        version: "0.1.0",
        subcommands: [ConfigCommand.self, InspectCommand.self, ChatCommand.self]
    )
}