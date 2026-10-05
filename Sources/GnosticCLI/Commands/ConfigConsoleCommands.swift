// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import GnosticHost
import GnosticKit

/// Shared `--experiments` and `--repository` options for registry-backed commands.
///
/// The registry is `Documentation/Architecture/experiments.json`. When neither
/// option is given the command looks for it under the current directory and
/// degrades gracefully when it is absent; an explicit path that is missing or
/// malformed is an error.
struct ExperimentsOptions: ParsableArguments {
    /// An explicit path to `experiments.json`.
    @Option(name: .customLong("experiments"), help: "Path to experiments.json (defaults to the repository copy).")
    var experimentsPath: String?
    /// A repository root that holds `Documentation/Architecture/experiments.json`.
    @Option(name: .customLong("repository"), help: "Repository root that holds Documentation/Architecture/experiments.json.")
    var repository: String?

    /// Creates the option group.
    init() {}

    /// Loads the registry, or returns `nil` when the default copy is absent.
    ///
    /// - Returns: The registry, or `nil`.
    /// - Throws: A decoding or file error for an explicit, unreadable path.
    func registry() throws -> ModuleRegistry? {
        if let experimentsPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: experimentsPath))
            return try JSONDecoder().decode(ModuleRegistry.self, from: data)
        }
        let root: URL
        if let repository {
            root = URL(fileURLWithPath: repository)
        } else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let url = ModuleRegistry.path(relativeTo: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ModuleRegistry.load(relativeTo: root)
    }
}

/// gnostic config module — list and select compiled-in modules.
struct ConfigModuleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "module",
        abstract: "List compiled-in modules and manage an Ascendant's selection.",
        discussion: """
        Modules are selected per Ascendant through the backend-owned \
        `extensions` setting. `config module list` shows each module's registry \
        status, its requirements, and its keys; `enable` and `disable` change \
        one Ascendant's selection.

          gnostic config module list --format json
          gnostic config module enable <ascendant-id> rlm
          gnostic config module keys <ascendant-id>
        """,
        subcommands: [List.self, Enable.self, Disable.self, Keys.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List compiled-in modules and their registry status.")
        @OptionGroup var experiments: ExperimentsOptions
        @OptionGroup var formatOptions: OutputFormatOptions

        func run() async throws {
            let format = try formatOptions.resolved()
            let registry = try experiments.registry()
            let entries = ConfigConsoleLogic.modules(registry: registry)
            switch format {
            case .human:
                print(HumanRender.moduleList(entries))
            case .json:
                print(try JSONOutput.encode(entries))
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "enable", abstract: "Select a module on one Ascendant.")
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?
        @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
        var dryRun = false
        @OptionGroup var experiments: ExperimentsOptions
        @OptionGroup var formatOptions: OutputFormatOptions
        @Argument(help: "Existing Ascendant UUID.")
        var ascendantID: String
        @Argument(help: "Module selection name, for example rlm.")
        var module: String

        func run() async throws {
            let format = try formatOptions.resolved()
            let registry = try experiments.registry()
            let store = ConfigCommandLogic.store(for: configPath)
            if dryRun {
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: true) { preview in
                    try ConfigConsoleLogic.enableModule(ascendantID: ascendantID, module: module, store: preview, registry: registry)
                }
                return
            }
            let mutation = try ConfigConsoleLogic.enableModule(ascendantID: ascendantID, module: module, store: store, registry: registry)
            switch format {
            case .human:
                for warning in mutation.warnings { print("Warning: \(warning)") }
                print("Enabled module '\(mutation.module)' on \(mutation.ascendantID.uuidString.lowercased()).")
            case .json:
                print(try JSONOutput.encode(mutation))
            }
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "disable", abstract: "Remove a module from one Ascendant's selection.")
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?
        @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
        var dryRun = false
        @OptionGroup var experiments: ExperimentsOptions
        @OptionGroup var formatOptions: OutputFormatOptions
        @Argument(help: "Existing Ascendant UUID.")
        var ascendantID: String
        @Argument(help: "Module selection name, for example rlm.")
        var module: String

        func run() async throws {
            let format = try formatOptions.resolved()
            let registry = try experiments.registry()
            let store = ConfigCommandLogic.store(for: configPath)
            if dryRun {
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: true) { preview in
                    try ConfigConsoleLogic.disableModule(ascendantID: ascendantID, module: module, store: preview, registry: registry)
                }
                return
            }
            let mutation = try ConfigConsoleLogic.disableModule(ascendantID: ascendantID, module: module, store: store, registry: registry)
            switch format {
            case .human:
                print("Disabled module '\(mutation.module)' on \(mutation.ascendantID.uuidString.lowercased()).")
            case .json:
                print(try JSONOutput.encode(mutation))
            }
        }
    }

    struct Keys: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "keys", abstract: "List the modules and keys one Ascendant selects.")
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?
        @OptionGroup var formatOptions: OutputFormatOptions
        @Argument(help: "Existing Ascendant UUID.")
        var ascendantID: String

        func run() async throws {
            let format = try formatOptions.resolved()
            let entries = try ConfigConsoleLogic.moduleKeys(
                ascendantID: ascendantID,
                store: ConfigCommandLogic.store(for: configPath)
            )
            switch format {
            case .human:
                print(HumanRender.moduleKeys(entries))
            case .json:
                print(try JSONOutput.encode(entries))
            }
        }
    }
}

/// gnostic config regime — print the resolved Regime for an Ascendant.
struct ConfigRegimeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "regime",
        abstract: "Inspect the Regime an Ascendant resolves to.",
        subcommands: [Show.self]
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the resolved Regime: backend kind, modules, model tiers, and policy.",
            discussion: """
            The module list comes from the same composition source `serve` uses, \
            so it cannot drift from the composed runtime. Secret values are never \
            part of the output.
            """
        )
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?
        @OptionGroup var experiments: ExperimentsOptions
        @OptionGroup var formatOptions: OutputFormatOptions
        @Argument(help: "Existing Ascendant UUID.")
        var ascendantID: String

        func run() async throws {
            let format = try formatOptions.resolved()
            let regime = try ConfigConsoleLogic.regime(
                ascendantID: ascendantID,
                store: ConfigCommandLogic.store(for: configPath),
                registry: try experiments.registry()
            )
            switch format {
            case .human:
                print(HumanRender.regime(regime))
            case .json:
                print(try JSONOutput.encode(regime))
            }
        }
    }
}

/// Human-readable rendering for the configuration console.
enum HumanRender {
    static func moduleList(_ entries: [ModuleConsoleEntry]) -> String {
        guard !entries.isEmpty else { return "No modules are compiled in." }
        var lines = ["module  registryID  status  contribution  model-service  keys"]
        for entry in entries {
            let keys = entry.keys.map(\.name).joined(separator: ",")
            lines.append(
                [
                    entry.name,
                    entry.registryID ?? "-",
                    entry.status,
                    entry.installsContribution ? "yes" : "no",
                    entry.requiresModelService ? "yes" : "no",
                    keys.isEmpty ? "-" : keys,
                ].joined(separator: "  ")
            )
        }
        for entry in entries {
            if let warning = entry.warning { lines.append("Warning: \(warning)") }
        }
        return lines.joined(separator: "\n")
    }

    static func moduleKeys(_ entries: [ModuleConsoleEntry]) -> String {
        guard !entries.isEmpty else { return "This Ascendant selects no modules." }
        var lines: [String] = []
        for entry in entries {
            lines.append("module: \(entry.name)")
            if entry.keys.isEmpty {
                lines.append("  (no keys)")
            }
            for key in entry.keys {
                let marker = key.isSecret ? " [secret]" : ""
                lines.append("  \(key.name)\(marker) — \(key.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func regime(_ regime: ExperimentRegime) -> String {
        var lines = [
            "backend.kind = \(regime.backendKind)",
            "provider = \(regime.provider.isEmpty ? "<unset>" : regime.provider)",
            "endpoint = \(regime.endpoint.isEmpty ? "<unset>" : regime.endpoint)",
        ]
        lines.append("modules = \(regime.modules.isEmpty ? "<none>" : regime.modules.joined(separator: ", "))")
        for tier in regime.modelTiers.keys.sorted() {
            lines.append("model.\(tier) = \(regime.modelTiers[tier] ?? "")")
        }
        for policy in regime.policies.keys.sorted() {
            lines.append("policy.\(policy) = \(regime.policies[policy] ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
