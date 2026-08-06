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
            let store = CLIConfigurationStore()
            let configuration = try store.load()
            print(store.redactedDescription(for: configuration))
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
            guard let parsedKey = ConfigurationKey(rawValue: key) else {
                throw CLIConfigurationError.unknownKey(key)
            }
            try CLIConfigurationStore().setValue(value, for: parsedKey)
            print("Set \(parsedKey.rawValue).")
        }
    }

    /// `gnostic config path` — print the config file location.
    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the config file path."
        )

        func run() async throws {
            print(CLIConfigurationStore().path().path)
        }
    }
}