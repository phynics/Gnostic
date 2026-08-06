// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// `gnostic config` — inspect and edit the CLI configuration store.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or edit the gnostic configuration.",
        subcommands: [Show.self, Set.self, Path.self]
    )

    /// `gnostic config show` — print the effective (redacted) configuration.
    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the effective configuration with secrets redacted."
        )

        func run() async throws {
            try ConfigCommandLogic.show()
        }
    }

    /// `gnostic config set <key> <value>` — persist a validated value.
    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set a configuration key to a value."
        )

        @Argument(help: "Dotted configuration key (e.g. mqtt.host).")
        var key: String

        @Argument(help: "Value to store.")
        var value: String

        func run() async throws {
            try ConfigCommandLogic.set(key: key, value: value)
        }
    }

    /// `gnostic config path` — print the config file location.
    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the config file path."
        )

        func run() async throws {
            try ConfigCommandLogic.path()
        }
    }
}

/// The testable logic behind the `config` subcommands.
///
/// Each function accepts an explicit store and output sink so tests exercise
/// the exact code the commands run without touching ArgumentParser's Codable
/// synthesis.
public enum ConfigCommandLogic {
    /// `config show`
    public static func show(store: CLIConfigurationStore = CLIConfigurationStore(), writeOutput: (String) -> Void = { print($0) }) throws {
        let configuration = try store.load()
        writeOutput(store.redactedDescription(for: configuration))
    }

    /// `config set <key> <value>`
    public static func set(key: String, value: String, store: CLIConfigurationStore = CLIConfigurationStore(), writeOutput: (String) -> Void = { print($0) }) throws {
        guard let parsedKey = ConfigurationKey(rawValue: key) else {
            throw CLIConfigurationError.unknownKey(key)
        }
        try store.setValue(value, for: parsedKey)
        writeOutput("Set \(parsedKey.rawValue).")
    }

    /// `config path`
    public static func path(store: CLIConfigurationStore = CLIConfigurationStore(), writeOutput: (String) -> Void = { print($0) }) throws {
        writeOutput(store.path().path)
    }
}