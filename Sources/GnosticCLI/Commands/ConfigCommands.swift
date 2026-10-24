// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import GnosticHost

/// gnostic config — create and manage the versioned Node resource graph.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Create and manage the Gnostic Node configuration.",
        discussion: """
        Resources are addressed by UUID. Run `config show` to list them.

        Pass --config PATH after the subcommand, for example `gnostic config show --config PATH`.

        Example:
          gnostic config init
          gnostic config ascendant add "Agent" --kind acp-client
          gnostic config backend keys <ascendant-id>
          gnostic config backend set <ascendant-id> command /path/to/acp-agent
          gnostic config backend set-secret <ascendant-id> env-secret.API_TOKEN   # reads stdin
        """,
        subcommands: [
            Init.self, Show.self, Validate.self, Migrate.self, Path.self, Broker.self, Backend.self,
            Ascendant.self, Timeline.self, Workspace.self, ConfigModuleCommand.self,
            ConfigRegimeCommand.self,
        ]
    )

    func run() async throws {
        print(Self.helpMessage())
    }

    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "init", abstract: "Create a default schema-v2 Node manifest.")
        @OptionGroup var configOptions: ConfigPathOptions
        @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
        var dryRun = false

        func run() async throws {
            let store = configOptions.store()
            if dryRun {
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: true) { preview in
                    try ConfigCommandLogic.initialize(store: preview, writeOutput: { _ in })
                }
                return
            }
            try ConfigCommandLogic.initialize(store: store)
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the effective configuration with secrets redacted (resource manifest).")
        @OptionGroup var configOptions: ConfigPathOptions
        @Flag(name: .customLong("json"), help: "Print redacted JSON instead of the human-readable view.")
        var json = false
        @Option(name: .customLong("format"), help: "Output format: human or json.")
        var format: String?

        func run() async throws {
            if let format, !["human", "json"].contains(format.lowercased()) {
                throw ValidationError("Output format must be human or json.")
            }
            try ConfigCommandLogic.show(
                store: configOptions.store(),
                json: json || format?.lowercased() == "json"
            )
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "validate", abstract: "Validate the complete manifest without changing it.")
        @OptionGroup var configOptions: ConfigPathOptions
        @OptionGroup var formatOptions: OutputFormatOptions

        func run() async throws {
            let format = try formatOptions.resolved()
            let report = ConfigConsoleLogic.validationReport(store: configOptions.store())
            switch format {
            case .human:
                if report.valid {
                    print("Configuration is valid.")
                } else {
                    for issue in report.issues {
                        print("\(issue.message)")
                        print("  path: \(issue.path)")
                        print("  reason: \(issue.reasonCode)")
                        print("  hint: \(issue.hint)")
                    }
                }
            case .json:
                print(try JSONOutput.encode(report))
            }
            if !report.valid { throw ExitCode.failure }
        }
    }

    struct Migrate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "migrate",
            abstract: "Migrate an immediate pre-v0.5 schema-v2 manifest to Runtime instance configuration."
        )
        @OptionGroup var configOptions: ConfigPathOptions
        @Flag(name: .customLong("dry-run"), help: "Show the structured migration diff without writing or backing up the source.")
        var dryRun = false
        @OptionGroup var formatOptions: OutputFormatOptions

        func run() async throws {
            let format = try formatOptions.resolved()
            let report = try ConfigurationMigration.migrate(at: configOptions.store().path(), dryRun: dryRun)
            switch format {
            case .json:
                print(try JSONOutput.encode(report))
            case .human:
                print(dryRun ? "Configuration migration preview (no files changed):" : "Configuration migrated:")
                print("  source: \(report.source)")
                if let backup = report.backup { print("  backup: \(backup)") }
                for change in report.changedFields { print("  change: \(change)") }
                print("  preserved Node: \(report.preservedNodeID.uuidString)")
                print("  preserved Runtime instances: \(report.preservedRuntimeInstanceIDs.count)")
                print("  preserved Timelines: \(report.preservedTimelineIDs.count)")
                print("  preserved Workspaces: \(report.preservedWorkspaceIDs.count)")
            }
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the config file path (selected resource manifest).")
        @OptionGroup var configOptions: ConfigPathOptions

        func run() async throws {
            try ConfigCommandLogic.path(store: configOptions.store())
        }
    }

    struct Broker: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "broker",
            abstract: "Configure the MQTT broker.",
            subcommands: [BrokerSet.self, BrokerSetPassword.self]
        )

        struct BrokerSet: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set", abstract: "Set broker host, port, namespace, or username.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Option(name: .long, help: "MQTT broker host.")
            var host: String?
            @Option(name: .long, help: "MQTT broker port.")
            var port: Int?
            @Option(name: .long, help: "MQTT topic namespace.")
            var namespace: String?
            @Option(name: .long, help: "MQTT username.")
            var username: String?
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.setBroker(
                        host: host, port: port, namespace: namespace, username: username,
                        store: target
                    )
                }
            }
        }

        struct BrokerSetPassword: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set-password", abstract: "Read the broker password from standard input.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                let password = ConfigCommandLogic.readSecret()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.setBrokerPassword(password, store: target)
                }
            }
        }
    }

    /// gnostic config backend — configure any registered backend kind.
    struct Backend: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "backend",
            abstract: "Configure an Ascendant's backend, whatever its kind.",
            discussion: """
            Keys are those the Ascendant's backend kind advertises. Run \
            `config backend keys <ascendant-id>` to list them.

            Secrets are written with `set-secret`, which reads the value from \
            standard input so it never appears in shell history, and are \
            redacted by `config show`.
            """,
            subcommands: [Set.self, SetSecret.self, Keys.self, Clear.self]
        )

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set",
                abstract: "Set one non-secret backend setting."
            )
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing Ascendant UUID.")
            var ascendantID: String
            @Argument(help: "Setting key advertised by the Ascendant's backend kind.")
            var key: String
            @Argument(help: "Value to store.")
            var value: String
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.setBackendValue(
                        ascendantID: ascendantID, key: key, value: value,
                        store: target
                    )
                }
            }
        }

        struct SetSecret: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set-secret",
                abstract: "Read one backend secret from standard input."
            )
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing Ascendant UUID.")
            var ascendantID: String
            @Argument(help: "Secret key advertised by the Ascendant's backend kind.")
            var key: String
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                let value = ConfigCommandLogic.readSecret()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.setBackendSecret(
                        ascendantID: ascendantID, key: key, value: value,
                        store: target
                    )
                }
            }
        }

        struct Keys: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "keys",
                abstract: "List the keys this Ascendant's backend kind accepts."
            )
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing Ascendant UUID.")
            var ascendantID: String

            func run() async throws {
                try ConfigCommandLogic.listBackendKeys(
                    ascendantID: ascendantID, store: configOptions.store()
                )
            }
        }

        struct Clear: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "clear",
                abstract: "Clear the backend envelope, preserving its kind."
            )
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing Ascendant UUID.")
            var ascendantID: String
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.clearBackend(ascendantID: ascendantID, store: target)
                }
            }
        }
    }

    struct Ascendant: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ascendant",
            abstract: "Manage Ascendants and their backend kind.",
            discussion: """
            Adding an Ascendant also creates the Timeline it operates, atomically.

              gnostic config ascendant add "Atlas"
              gnostic config ascendant add "Agent" --kind acp-client
              gnostic config ascendant update <id> --name "Atlas II"
            """,
            subcommands: [AscendantAdd.self, AscendantUpdate.self, AscendantRemove.self]
        )

        struct AscendantAdd: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an Ascendant and its operated default Timeline atomically.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Ascendant name. Takes precedence over --name if both are given.")
            var nameArgument: String?
            @Option(name: .long, help: "Ascendant name. Equivalent to the positional argument.")
            var name: String?
            @Option(name: .long, help: "Ascendant description.")
            var description: String = ""
            @Option(name: .long, help: "Backend kind. Must be registered; see 'config backend keys'.")
            var kind: String = "acp-client"
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false
            func run() async throws {
                // The positional wins so that `add "Atlas" --name Other` is not
                // silently resolved in favour of the less visible spelling.
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.addAscendant(
                        name: nameArgument ?? name, description: description, kind: kind,
                        store: target, writeOutput: dryRun ? { _ in } : { print($0) }
                    )
                }
            }
        }

        struct AscendantUpdate: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an Ascendant without changing its ID or kind.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing Ascendant UUID.")
            var id: String
            @Option(name: .long, help: "New Ascendant name.")
            var name: String?
            @Option(name: .long, help: "New Ascendant description.")
            var description: String?
            @Option(name: .customLong("default-timeline"), help: "Existing Timeline operated by this Ascendant.")
            var defaultTimeline: String?
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.updateAscendant(
                        id: id, name: name, description: description, defaultTimelineID: defaultTimeline,
                        store: target
                    )
                }
            }
        }

        struct AscendantRemove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an Ascendant and clear its operator from every Timeline.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing resource UUID.")
            var id: String
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.removeAscendant(id: id, store: target)
                }
            }
        }
    }

    struct Timeline: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "timeline",
            abstract: "Manage independent Timelines and Workspace attachments.",
            discussion: """
            A Timeline may be operated by an Ascendant and may have Workspaces \
            attached. Network attachments carry a URI and resolve lazily.

              gnostic config timeline add "Notes"
              gnostic config timeline add "Repository" --project-local /work/repository
              gnostic config timeline update <timeline-id> --project-scratch
              gnostic config timeline attach-workspace <timeline-id> <workspace-id>
              gnostic config timeline detach-workspace <timeline-id> <workspace-id>
            """,
            subcommands: [TimelineAdd.self, TimelineUpdate.self, TimelineRemove.self, AttachWorkspace.self, DetachWorkspace.self]
        )

        struct TimelineAdd: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a Timeline, optionally operated by an Ascendant.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Timeline title (also accepted as --title).")
            var titleArgument: String?
            @Option(name: .long, help: "Timeline title. Equivalent to the positional argument.")
            var title: String?
            @Option(name: .customLong("operating-ascendant"), help: "Existing Ascendant UUID.")
            var operatingAscendant: String?
            @Option(name: .customLong("project-local"), help: "Use this absolute local directory as the Runtime Session cwd.")
            var projectLocal: String?
            @Flag(name: .customLong("project-scratch"), help: "Use a clean Gnostic-managed scratch directory for the Runtime Session.")
            var projectScratch = false
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                if projectLocal != nil && projectScratch {
                    throw ValidationError("Use either --project-local or --project-scratch, not both.")
                }
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.addTimeline(
                        title: title ?? titleArgument, operatingAscendantID: operatingAscendant,
                        project: projectLocal.map(Project.local) ?? (projectScratch ? .scratch : nil),
                        store: target, writeOutput: dryRun ? { _ in } : { print($0) }
                    )
                }
            }
        }

        struct TimelineUpdate: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a Timeline without changing its ID or kind.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing Timeline UUID.")
            var id: String
            @Option(name: .long, help: "New Timeline title.")
            var title: String?
            @Option(name: .customLong("operating-ascendant"), help: "Ascendant UUID that operates this Timeline.")
            var operatingAscendant: String?
            @Flag(name: .customLong("clear-operating-ascendant"), help: "Leave this Timeline without an operating Ascendant.")
            var clearOperatingAscendant = false
            @Option(name: .customLong("project-local"), help: "Set the local Project directory used as the Runtime Session cwd.")
            var projectLocal: String?
            @Flag(name: .customLong("project-scratch"), help: "Set the Project to a clean Gnostic-managed scratch directory.")
            var projectScratch = false
            @Flag(name: .customLong("clear-project"), help: "Remove the configured Project; the Runtime will use scratch placement.")
            var clearProject = false
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                if operatingAscendant != nil && clearOperatingAscendant {
                    throw ValidationError("Use either --operating-ascendant or --clear-operating-ascendant, not both.")
                }
                if [projectLocal != nil, projectScratch, clearProject].filter({ $0 }).count > 1 {
                    throw ValidationError("Use only one of --project-local, --project-scratch, or --clear-project.")
                }
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.updateTimeline(
                        id: id, title: title, operatingAscendantID: operatingAscendant,
                        clearOperatingAscendant: clearOperatingAscendant,
                        project: projectLocal.map(Project.local) ?? (projectScratch ? .scratch : nil),
                        clearProject: clearProject,
                        store: target
                    )
                }
            }
        }

        struct TimelineRemove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a Timeline that is not an Ascendant default.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing resource UUID.")
            var id: String
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.removeTimeline(id: id, store: target)
                }
            }
        }

        struct AttachWorkspace: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "attach-workspace", abstract: "Attach a local Workspace or a lazy network Workspace reference.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Timeline UUID, followed by Workspace UUID; with --timeline, this is the Workspace UUID.")
            var firstID: String
            @Argument(help: "Workspace UUID when the Timeline UUID is positional.")
            var secondID: String?
            @Option(name: .customLong("timeline"), help: "Timeline UUID.")
            var timelineOption: String?
            @Option(name: .customLong("network"), help: "Network Workspace URI; omit for a local Workspace.")
            var networkURI: String?
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let timelineID = timelineOption ?? secondID.map { _ in firstID }
                let workspaceID = timelineID == nil ? secondID : firstID
                guard let timelineID, let workspaceID else {
                    throw ValidationError("Provide a Timeline UUID and Workspace UUID.")
                }
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.attachWorkspace(
                        timelineID: timelineID, workspaceID: workspaceID, networkURI: networkURI,
                        store: target
                    )
                }
            }
        }

        struct DetachWorkspace: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "detach-workspace", abstract: "Detach a Workspace from a Timeline.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Timeline UUID, followed by Workspace UUID; with --timeline, this is the Workspace UUID.")
            var firstID: String
            @Argument(help: "Workspace UUID when the Timeline UUID is positional.")
            var secondID: String?
            @Option(name: .customLong("timeline"), help: "Timeline UUID.")
            var timelineOption: String?
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let timelineID = timelineOption ?? secondID.map { _ in firstID }
                let workspaceID = timelineID == nil ? secondID : firstID
                guard let timelineID, let workspaceID else {
                    throw ValidationError("Provide a Timeline UUID and Workspace UUID.")
                }
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.detachWorkspace(
                        timelineID: timelineID, workspaceID: workspaceID,
                        store: target
                    )
                }
            }
        }
    }

    struct Workspace: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "workspace",
            abstract: "Manage local Workspaces.",
            discussion: """
            A host must register a local Workspace adapter for the configured \
            kind before it can serve that Workspace. The default `gnostic` host \
            registers no local Workspace adapters.
            """,
            subcommands: [WorkspaceAdd.self, WorkspaceUpdate.self, WorkspaceRemove.self]
        )

        struct WorkspaceAdd: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a local Workspace.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Workspace name (also accepted as --name).")
            var nameArgument: String?
            @Option(name: .long, help: "Workspace name. Equivalent to the positional argument.")
            var name: String?
            @Option(name: .long, help: "Workspace URI.")
            var uri: String
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.addWorkspace(
                        name: name ?? nameArgument, uri: uri,
                        store: target, writeOutput: dryRun ? { _ in } : { print($0) }
                    )
                }
            }
        }

        struct WorkspaceUpdate: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a Workspace without changing its ID or kind.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing Workspace UUID.")
            var id: String
            @Option(name: .long, help: "New Workspace name.")
            var name: String?
            @Option(name: .long, help: "New Workspace URI.")
            var uri: String?
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.updateWorkspace(
                        id: id, name: name, uri: uri,
                        store: target
                    )
                }
            }
        }

        struct WorkspaceRemove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a Workspace that has no local attachments.")
            @OptionGroup var configOptions: ConfigPathOptions
            @Argument(help: "Existing resource UUID.")
            var id: String
            @Flag(name: .customLong("dry-run"), help: "Print the resulting manifest diff without writing it.")
            var dryRun = false

            func run() async throws {
                let store = configOptions.store()
                try ConfigConsoleLogic.applyMutation(store: store, dryRun: dryRun) { target in
                    try ConfigCommandLogic.removeWorkspace(id: id, store: target)
                }
            }
        }
    }

}

/// Testable logic behind the resource commands.
public enum ConfigCommandLogic {
    /// The manifest store for a parsed `--config` value. A pure function of its
    /// input: `nil` selects `GNOSTIC_CONFIG` and then the default location.
    public static func store(for configPath: String?) -> CLIConfigurationStore {
        CLIConfigurationStore(configPath: configPath.map(URL.init(fileURLWithPath:)))
    }

    public static func readSecret() -> String {
        var value = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        while value.last == "\n" || value.last == "\r" { value.removeLast() }
        return value
    }

    public static func initialize(store: CLIConfigurationStore = CLIConfigurationStore(), writeOutput: (String) -> Void = { print($0) }) throws {
        writeOutput(initializationSummary(try store.initializeManifest()))
    }

    public static func show(store: CLIConfigurationStore = CLIConfigurationStore(), json: Bool = false, writeOutput: (String) -> Void = { print($0) }) throws {
        let manifest = try store.loadManifest()
        writeOutput(json ? manifest.redactedDescription() : humanDescription(manifest))
    }

    public static func validate(store: CLIConfigurationStore = CLIConfigurationStore(), writeOutput: (String) -> Void = { print($0) }) throws {
        let manifest = try store.loadManifest()
        try manifest.validate()
        try manifest.validateBrokerCredentials()
        writeOutput("Configuration is valid.")
    }

    public static func path(store: CLIConfigurationStore = CLIConfigurationStore(), writeOutput: (String) -> Void = { print($0) }) throws {
        writeOutput(store.path().path)
    }

    public static func setBroker(host: String?, port: Int?, namespace: String?, username: String?, store: CLIConfigurationStore) throws {
        guard host != nil || port != nil || namespace != nil || username != nil else { throw CLIConfigurationError.invalidArgument("Provide at least one broker field to set.") }
        _ = try store.mutateManifest { manifest in
            if let host { manifest.broker.host = host }
            if let port { manifest.broker.port = port }
            if let namespace { manifest.broker.namespace = namespace }
            if let username { manifest.broker.username = username }
        }
    }

    public static func setBrokerPassword(_ password: String, store: CLIConfigurationStore) throws {
        _ = try store.mutateManifest { $0.broker.password = password.isEmpty ? nil : password }
    }

    /// Resolves the Ascendant at `ascendantID` and the schema of its kind.
    ///
    /// The registry comes from the supplied composition source, so a kind known
    /// to `serve` is known here too. Resolving a schema never constructs a
    /// backend or a language model.
    private static func backendTarget(
        _ ascendantID: String,
        in manifest: NodeManifest,
        composition: BackendComposition
    ) throws -> (index: Int, kind: String, schema: AscendantBackendSettingsSchema) {
        let id = try parseID(ascendantID, kind: "ascendant")
        guard let index = manifest.ascendants.firstIndex(where: { $0.id == id }) else {
            throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: id)
        }
        let kind = manifest.ascendants[index].backend.kind
        guard let schema = composition.settingsSchema(for: kind) else {
            throw CLIConfigurationError.invalidArgument(
                unavailableBackendKindMessage(kind, composition: composition)
            )
        }
        return (index, kind, schema)
    }

    private static func knownKindList(_ composition: BackendComposition) -> String {
        composition.registeredKinds.sorted().joined(separator: ", ")
    }

    private static func unavailableBackendKindMessage(
        _ kind: String,
        composition: BackendComposition
    ) -> String {
        if kind == "positronic" || kind == "letta" {
            return "Backend kind '\(kind)' was removed. Configure an ACP v2 Runtime with `gnostic config ascendant add --kind acp-client`. Historical execution state is not converted."
        }
        return "Backend kind '\(kind)' is not registered. Known kinds: \(knownKindList(composition))."
    }

    /// Validates one key against the kind's advertised schema.
    ///
    /// A kind that advertises no keys accepts any key: it can be built but
    /// cannot describe itself, so the CLI must not pretend to know better.
    private static func validatedKey(
        _ key: String,
        wantsSecret: Bool,
        kind: String,
        schema: AscendantBackendSettingsSchema
    ) throws {
        guard !key.isEmpty else {
            throw CLIConfigurationError.invalidArgument("A backend key cannot be empty.")
        }
        guard !schema.isUnspecified else { return }
        let declaredSecret: Bool
        if let declared = schema.key(named: key) {
            declaredSecret = declared.isSecret
        } else if let dynamic = schema.dynamicFamily(matching: key) {
            guard AscendantBackendSettingsSchema.isValidEnvironmentVariableName(dynamic.member) else {
                throw CLIConfigurationError.invalidArgument(
                    "Backend key '\(key)' must end with a valid environment-variable name."
                )
            }
            declaredSecret = dynamic.family.isSecret
        } else {
            let knownKeys = schema.keys.map(\.name)
            let knownFamilies = schema.keyFamilies.map { "\($0.prefix)<VARIABLE>" }
            let known = (knownKeys + knownFamilies).joined(separator: ", ")
            throw CLIConfigurationError.invalidArgument(
                "Backend kind '\(kind)' does not accept key '\(key)'. Accepted keys: \(known)."
            )
        }
        if declaredSecret != wantsSecret {
            throw CLIConfigurationError.invalidArgument(
                declaredSecret
                    ? "Key '\(key)' is a secret. Use 'config backend set-secret', which reads the value from standard input."
                    : "Key '\(key)' is not a secret. Use 'config backend set'."
            )
        }
    }

    /// Sets one non-secret backend setting.
    public static func setBackendValue(
        ascendantID: String,
        key: String,
        value: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default
    ) throws {
        _ = try store.mutateManifest { manifest in
            let target = try backendTarget(ascendantID, in: manifest, composition: composition)
            try validatedKey(key, wantsSecret: false, kind: target.kind, schema: target.schema)
            manifest.ascendants[target.index].backend.settings[key] = .string(value)
        }
    }

    /// Sets one backend secret, read from standard input by the command layer.
    public static func setBackendSecret(
        ascendantID: String,
        key: String,
        value: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default
    ) throws {
        _ = try store.mutateManifest { manifest in
            let target = try backendTarget(ascendantID, in: manifest, composition: composition)
            try validatedKey(key, wantsSecret: true, kind: target.kind, schema: target.schema)
            manifest.ascendants[target.index].backend.secrets[key] = .string(value)
        }
    }

    /// Clears one Ascendant's backend envelope, preserving its kind.
    public static func clearBackend(
        ascendantID: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default
    ) throws {
        _ = try store.mutateManifest { manifest in
            let target = try backendTarget(ascendantID, in: manifest, composition: composition)
            manifest.ascendants[target.index].backend = .init(kind: target.kind)
        }
    }

    /// Prints the keys one Ascendant's backend kind accepts.
    public static func listBackendKeys(
        ascendantID: String,
        store: CLIConfigurationStore,
        composition: BackendComposition = .default,
        writeOutput: (String) -> Void = { print($0) }
    ) throws {
        let manifest = try store.loadManifest()
        let target = try backendTarget(ascendantID, in: manifest, composition: composition)
        guard !target.schema.isUnspecified else {
            writeOutput("Backend kind '\(target.kind)' does not advertise its configuration keys.")
            return
        }
        writeOutput("kind: \(target.kind)")
        for key in target.schema.keys {
            let marker = key.isSecret ? " [secret]" : ""
            writeOutput("  \(key.name)\(marker) — \(key.summary)")
        }
        for family in target.schema.keyFamilies {
            let marker = family.isSecret ? " [secret]" : ""
            writeOutput("  \(family.prefix)<VARIABLE>\(marker) — \(family.summary)")
        }
    }

    public static func addAscendant(
        name: String?,
        description: String,
        kind: String = "acp-client",
        store: CLIConfigurationStore,
        composition: BackendComposition = .default,
        writeOutput: (String) -> Void = { print($0) }
    ) throws {
        guard let name, !name.isEmpty else { throw CLIConfigurationError.invalidArgument("An Ascendant name is required.") }
        guard composition.registeredKinds.contains(kind) else {
            throw CLIConfigurationError.invalidArgument(
                unavailableBackendKindMessage(kind, composition: composition)
            )
        }
        let ascendantID = UUID.makeVersion4()
        let timelineID = UUID.makeVersion4()
        _ = try store.mutateManifest { manifest in
            manifest.ascendants.append(.init(id: ascendantID, name: name, defaultTimelineID: timelineID, description: description, backend: .init(kind: kind)))
            manifest.timelines.append(.init(id: timelineID, title: "\(name) Timeline", operatingAscendantID: ascendantID))
        }
        printID("Added ascendant", ascendantID, writeOutput: writeOutput)
        printID("Added default timeline", timelineID, writeOutput: writeOutput)
    }

    public static func updateAscendant(
        id: String,
        name: String?,
        description: String?,
        defaultTimelineID: String?,
        store: CLIConfigurationStore
    ) throws {
        let ascendantID = try parseID(id, kind: "ascendant")
        let timelineID = try defaultTimelineID.map { try parseID($0, kind: "timeline") }
        _ = try store.mutateManifest { manifest in
            guard let index = manifest.ascendants.firstIndex(where: { $0.id == ascendantID }) else { throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: ascendantID) }
            if let name { manifest.ascendants[index].name = name }
            if let description { manifest.ascendants[index].description = description }
            if let timelineID {
                guard manifest.timelines.contains(where: { $0.id == timelineID && $0.operatingAscendantID == ascendantID }) else { throw CLIConfigurationError.invalidArgument("Default Timeline \(timelineID.uuidString.lowercased()) must exist and be operated by Ascendant \(ascendantID.uuidString.lowercased()).") }
                manifest.ascendants[index].defaultTimelineID = timelineID
            }
        }
    }

    public static func removeAscendant(id: String, store: CLIConfigurationStore) throws {
        let ascendantID = try parseID(id, kind: "ascendant")
        _ = try store.mutateManifest { manifest in
            guard manifest.ascendants.contains(where: { $0.id == ascendantID }) else { throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: ascendantID) }
            manifest.ascendants.removeAll { $0.id == ascendantID }
            for index in manifest.timelines.indices where manifest.timelines[index].operatingAscendantID == ascendantID { manifest.timelines[index].operatingAscendantID = nil }
        }
    }

    public static func addTimeline(title: String?, operatingAscendantID: String?, project: Project? = nil, store: CLIConfigurationStore, writeOutput: (String) -> Void = { print($0) }) throws {
        guard let title, !title.isEmpty else { throw CLIConfigurationError.invalidArgument("A Timeline title is required.") }
        let timelineID = UUID.makeVersion4()
        let ascendantID = try operatingAscendantID.map { try parseID($0, kind: "ascendant") }
        _ = try store.mutateManifest { manifest in
            if let ascendantID, !manifest.ascendants.contains(where: { $0.id == ascendantID }) { throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: ascendantID) }
            manifest.timelines.append(.init(id: timelineID, title: title, operatingAscendantID: ascendantID, project: project))
        }
        printID("Added timeline", timelineID, writeOutput: writeOutput)
    }

    public static func updateTimeline(
        id: String,
        title: String?,
        operatingAscendantID: String?,
        clearOperatingAscendant: Bool = false,
        project: Project? = nil,
        clearProject: Bool = false,
        store: CLIConfigurationStore
    ) throws {
        let timelineID = try parseID(id, kind: "timeline")
        let ascendantID = try operatingAscendantID.map { try parseID($0, kind: "ascendant") }
        _ = try store.mutateManifest { manifest in
            guard let index = manifest.timelines.firstIndex(where: { $0.id == timelineID }) else { throw CLIConfigurationError.resourceNotFound(kind: "timeline", id: timelineID) }
            if let title { manifest.timelines[index].title = title }
            if clearOperatingAscendant {
                manifest.timelines[index].operatingAscendantID = nil
            } else if operatingAscendantID != nil {
                guard let ascendantID, manifest.ascendants.contains(where: { $0.id == ascendantID }) else { throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: ascendantID ?? UUID()) }
                manifest.timelines[index].operatingAscendantID = ascendantID
            }
            if clearProject {
                manifest.timelines[index].project = nil
            } else if let project {
                manifest.timelines[index].project = project
            }
        }
    }

    public static func removeTimeline(id: String, store: CLIConfigurationStore) throws {
        let timelineID = try parseID(id, kind: "timeline")
        _ = try store.mutateManifest { manifest in
            guard manifest.timelines.contains(where: { $0.id == timelineID }) else { throw CLIConfigurationError.resourceNotFound(kind: "timeline", id: timelineID) }
            let references = manifest.ascendants.filter { $0.defaultTimelineID == timelineID }.map { "ascendant \($0.id.uuidString.lowercased())" }
            guard references.isEmpty else { throw CLIConfigurationError.resourceReferenced(kind: "timeline", id: timelineID, references: references) }
            manifest.timelines.removeAll { $0.id == timelineID }
        }
    }

    public static func attachWorkspace(timelineID: String, workspaceID: String, networkURI: String?, store: CLIConfigurationStore) throws {
        let timelineUUID = try parseID(timelineID, kind: "timeline")
        let workspaceUUID = try parseID(workspaceID, kind: "workspace")
        _ = try store.mutateManifest { manifest in
            guard let index = manifest.timelines.firstIndex(where: { $0.id == timelineUUID }) else { throw CLIConfigurationError.resourceNotFound(kind: "timeline", id: timelineUUID) }
            if let networkURI {
                guard !networkURI.isEmpty else { throw CLIConfigurationError.invalidArgument("A network Workspace URI is required.") }
                manifest.timelines[index].attachments.removeAll { $0.workspaceID == workspaceUUID }
                manifest.timelines[index].attachments.append(.network(workspaceUUID, uri: networkURI))
            } else {
                guard manifest.workspaces.contains(where: { $0.id == workspaceUUID }) else { throw CLIConfigurationError.resourceNotFound(kind: "workspace", id: workspaceUUID) }
                manifest.timelines[index].attachments.removeAll { $0.workspaceID == workspaceUUID }
                manifest.timelines[index].attachments.append(.local(workspaceUUID))
            }
        }
    }

    public static func detachWorkspace(timelineID: String, workspaceID: String, store: CLIConfigurationStore) throws {
        let timelineUUID = try parseID(timelineID, kind: "timeline")
        let workspaceUUID = try parseID(workspaceID, kind: "workspace")
        _ = try store.mutateManifest { manifest in
            guard let index = manifest.timelines.firstIndex(where: { $0.id == timelineUUID }) else { throw CLIConfigurationError.resourceNotFound(kind: "timeline", id: timelineUUID) }
            manifest.timelines[index].attachments.removeAll { $0.workspaceID == workspaceUUID }
        }
    }

    public static func addWorkspace(name: String?, uri: String, store: CLIConfigurationStore, writeOutput: (String) -> Void = { print($0) }) throws {
        guard let name, !name.isEmpty else { throw CLIConfigurationError.invalidArgument("A Workspace name is required.") }
        let workspaceID = UUID.makeVersion4()
        _ = try store.mutateManifest { $0.workspaces.append(.init(id: workspaceID, name: name, uri: uri)) }
        printID("Added workspace", workspaceID, writeOutput: writeOutput)
    }

    public static func updateWorkspace(id: String, name: String?, uri: String?, store: CLIConfigurationStore) throws {
        let workspaceID = try parseID(id, kind: "workspace")
        _ = try store.mutateManifest { manifest in
            guard let index = manifest.workspaces.firstIndex(where: { $0.id == workspaceID }) else { throw CLIConfigurationError.resourceNotFound(kind: "workspace", id: workspaceID) }
            if let name { manifest.workspaces[index].name = name }
            if let uri { manifest.workspaces[index].uri = uri }
        }
    }

    public static func removeWorkspace(id: String, store: CLIConfigurationStore) throws {
        let workspaceID = try parseID(id, kind: "workspace")
        _ = try store.mutateManifest { manifest in
            guard manifest.workspaces.contains(where: { $0.id == workspaceID }) else { throw CLIConfigurationError.resourceNotFound(kind: "workspace", id: workspaceID) }
            let references = manifest.timelines.flatMap { timeline in
                timeline.attachments.contains { $0.workspaceID == workspaceID && $0.scope == .local } ? ["timeline \(timeline.id.uuidString.lowercased())"] : []
            }
            guard references.isEmpty else { throw CLIConfigurationError.resourceReferenced(kind: "workspace", id: workspaceID, references: references) }
            manifest.workspaces.removeAll { $0.id == workspaceID }
        }
    }

    private static func parseID(_ raw: String, kind: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw CLIConfigurationError.invalidArgument("Invalid \(kind) UUID '\(raw)'.") }
        return id
    }


    private static func printID(_ label: String, _ id: UUID, writeOutput: (String) -> Void = { print($0) }) {
        writeOutput("\(label): \(id.uuidString.lowercased())")
    }

    private static func initializationSummary(_ manifest: NodeManifest) -> String {
        var lines = [
            "Initialized configuration.",
            "node: \(manifest.node.id.uuidString.lowercased())",
            "ascendant: \(manifest.ascendants[0].id.uuidString.lowercased())",
            "timeline: \(manifest.timelines[0].id.uuidString.lowercased())",
        ]
        if let workspace = manifest.workspaces.first {
            lines.append("workspace: \(workspace.id.uuidString.lowercased())")
        }
        return lines.joined(separator: "\n")
    }

    private static func humanDescription(_ manifest: NodeManifest) -> String {
        var lines = [
            "schemaVersion = \(manifest.schemaVersion)",
            "node.id = \(manifest.node.id.uuidString.lowercased())",
            "node.approvalMode = \(manifest.node.approvalMode)",
            "node.logLevel = \(manifest.node.logLevel)",
            "broker.host = \(manifest.broker.host)",
            "broker.port = \(manifest.broker.port)",
            "broker.namespace = \(manifest.broker.namespace)",
            "mqtt.host = \(manifest.broker.host)",
            "mqtt.port = \(manifest.broker.port)",
            "mqtt.namespace = \(manifest.broker.namespace)",
        ]
        if let username = manifest.broker.username { lines.append("broker.username = \(username)") }
        if manifest.broker.password != nil { lines.append("broker.password = <redacted>") }
        for ascendant in manifest.ascendants {
            lines.append("ascendant \(ascendant.id.uuidString.lowercased()) = \(ascendant.name) default=\(ascendant.defaultTimelineID.uuidString.lowercased())")
            if !ascendant.description.isEmpty { lines.append("  description = \(ascendant.description)") }
            lines.append("  backend.kind = \(ascendant.backend.kind)")
            // Redaction is structural: anything in `secrets` is hidden, whatever
            // its name and whatever kind declared it. A new backend's secret is
            // therefore redacted without a CLI change.
            for key in ascendant.backend.settings.keys.sorted() {
                let value = ascendant.backend.settings[key]?.stringValue ?? ""
                lines.append("  backend.\(key) = \(value)")
            }
            for key in ascendant.backend.secrets.keys.sorted() {
                lines.append("  backend.\(key) = <redacted>")
            }
        }
        for timeline in manifest.timelines {
            lines.append("timeline \(timeline.id.uuidString.lowercased()) = \(timeline.title)")
            if let operatorID = timeline.operatingAscendantID { lines.append("  operator = \(operatorID.uuidString.lowercased())") }
            for attachment in timeline.attachments {
                let scope = attachment.scope.rawValue
                let uri = attachment.uri.map { " \($0)" } ?? ""
                lines.append("  workspace = \(attachment.workspaceID.uuidString.lowercased()) [\(scope)]\(uri)")
            }
        }
        for workspace in manifest.workspaces { lines.append("workspace \(workspace.id.uuidString.lowercased()) = \(workspace.name) \(workspace.uri)") }
        return lines.joined(separator: "\n")
    }
}
