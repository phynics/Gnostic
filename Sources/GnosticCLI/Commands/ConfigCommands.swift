// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// gnostic config — create and manage the versioned Node resource graph.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Create and manage the Gnostic Node configuration.",
        subcommands: [
            Init.self, Show.self, Validate.self, Path.self, Broker.self, Positronic.self,
            Ascendant.self, Timeline.self, Workspace.self,
        ]
    )

    // Leaf commands also declare this option, allowing config <command>
    // --config path, the canonical spelling.
    @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
    var configPath: String?

    func run() async throws {
        print(Self.helpMessage())
    }

    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "init", abstract: "Create a default schema-v2 Node manifest.")
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?

        func run() async throws {
            try ConfigCommandLogic.initialize(store: ConfigCommandLogic.store(for: configPath))
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the effective configuration with secrets redacted (resource manifest).")
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?
        @Flag(name: .customLong("json"), help: "Print redacted JSON instead of the human-readable view.")
        var json = false
        @Option(name: .customLong("format"), help: "Output format: human or json.")
        var format: String?

        func run() async throws {
            if let format, !["human", "json"].contains(format.lowercased()) {
                throw ValidationError("Output format must be human or json.")
            }
            try ConfigCommandLogic.show(
                store: ConfigCommandLogic.store(for: configPath),
                json: json || format?.lowercased() == "json"
            )
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "validate", abstract: "Validate the complete manifest without changing it.")
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?

        func run() async throws {
            try ConfigCommandLogic.validate(store: ConfigCommandLogic.store(for: configPath))
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the config file path (selected resource manifest).")
        @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
        var configPath: String?

        func run() async throws {
            try ConfigCommandLogic.path(store: ConfigCommandLogic.store(for: configPath))
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
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Option(name: .long, help: "MQTT broker host.")
            var host: String?
            @Option(name: .long, help: "MQTT broker port.")
            var port: Int?
            @Option(name: .long, help: "MQTT topic namespace.")
            var namespace: String?
            @Option(name: .long, help: "MQTT username.")
            var username: String?

            func run() async throws {
                try ConfigCommandLogic.setBroker(
                    host: host, port: port, namespace: namespace, username: username,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct BrokerSetPassword: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set-password", abstract: "Read the broker password from standard input.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?

            func run() async throws {
                try ConfigCommandLogic.setBrokerPassword(
                    ConfigCommandLogic.readSecret(),
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }
    }

    struct Positronic: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "positronic",
            abstract: "Configure one Positronic Ascendant backend.",
            subcommands: [Set.self, SetAPIKey.self, Clear.self]
        )

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set", abstract: "Set fields on one Positronic Ascendant backend.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Existing Positronic Ascendant UUID.")
            var ascendantID: String
            @Option(name: .long, help: "Provider name.")
            var provider: String?
            @Option(name: .long, help: "Provider endpoint URL.")
            var endpoint: String?
            @Option(name: .long, help: "Primary model name.")
            var model: String?
            @Option(name: .customLong("utility-model"), help: "Utility model name.")
            var utilityModel: String?
            @Option(name: .customLong("fast-model"), help: "Fast model name.")
            var fastModel: String?

            func run() async throws {
                try ConfigCommandLogic.configurePositronic(
                    ascendantID: ascendantID, provider: provider, endpoint: endpoint,
                    model: model, utilityModel: utilityModel, fastModel: fastModel,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct SetAPIKey: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set-api-key", abstract: "Read a Positronic API key from standard input.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Existing Positronic Ascendant UUID.")
            var ascendantID: String

            func run() async throws {
                try ConfigCommandLogic.setPositronicAPIKey(
                    id: ascendantID, value: ConfigCommandLogic.readSecret(),
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct Clear: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "clear", abstract: "Clear the selected Positronic backend envelope.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Existing Positronic Ascendant UUID.")
            var ascendantID: String

            func run() async throws {
                try ConfigCommandLogic.clearPositronic(ascendantID: ascendantID, store: ConfigCommandLogic.store(for: configPath))
            }
        }
    }

    struct Ascendant: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ascendant",
            abstract: "Manage local Positronic Ascendants.",
            subcommands: [AscendantAdd.self, AscendantUpdate.self, AscendantRemove.self]
        )

        struct AscendantAdd: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an Ascendant and its operated default Timeline atomically.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Ascendant name (also accepted as --name).")
            var nameArgument: String?
            @Option(name: .long) var name: String?
            @Option(name: .long) var description: String = ""
            func run() async throws {
                try ConfigCommandLogic.addAscendant(
                    name: name ?? nameArgument, description: description,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct AscendantUpdate: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "update", abstract: "Update an Ascendant without changing its ID or kind.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument var id: String
            @Option(name: .long) var name: String?
            @Option(name: .long) var description: String?
            @Option(name: .customLong("default-timeline"), help: "Existing Timeline operated by this Ascendant.")
            var defaultTimeline: String?

            func run() async throws {
                try ConfigCommandLogic.updateAscendant(
                    id: id, name: name, description: description, defaultTimelineID: defaultTimeline,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct AscendantRemove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an Ascendant and clear its operator from every Timeline.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument var id: String

            func run() async throws {
                try ConfigCommandLogic.removeAscendant(id: id, store: ConfigCommandLogic.store(for: configPath))
            }
        }
    }

    struct Timeline: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "timeline",
            abstract: "Manage independent Timelines and Workspace attachments.",
            subcommands: [TimelineAdd.self, TimelineUpdate.self, TimelineRemove.self, AttachWorkspace.self, DetachWorkspace.self]
        )

        struct TimelineAdd: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a Timeline, optionally operated by an Ascendant.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Timeline title (also accepted as --title).")
            var titleArgument: String?
            @Option(name: .long) var title: String?
            @Option(name: .customLong("operating-ascendant"), help: "Existing Ascendant UUID.")
            var operatingAscendant: String?

            func run() async throws {
                try ConfigCommandLogic.addTimeline(
                    title: title ?? titleArgument, operatingAscendantID: operatingAscendant,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct TimelineUpdate: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a Timeline without changing its ID or kind.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument var id: String
            @Option(name: .long) var title: String?
            @Option(name: .customLong("operating-ascendant")) var operatingAscendant: String?
            @Flag(name: .customLong("clear-operating-ascendant"), help: "Leave this Timeline without an operating Ascendant.")
            var clearOperatingAscendant = false

            func run() async throws {
                if operatingAscendant != nil && clearOperatingAscendant {
                    throw ValidationError("Use either --operating-ascendant or --clear-operating-ascendant, not both.")
                }
                try ConfigCommandLogic.updateTimeline(
                    id: id, title: title, operatingAscendantID: operatingAscendant,
                    clearOperatingAscendant: clearOperatingAscendant,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct TimelineRemove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a Timeline that is not an Ascendant default.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument var id: String

            func run() async throws {
                try ConfigCommandLogic.removeTimeline(id: id, store: ConfigCommandLogic.store(for: configPath))
            }
        }

        struct AttachWorkspace: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "attach-workspace", abstract: "Attach a local Workspace or a lazy network Workspace reference.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Timeline UUID, followed by Workspace UUID; with --timeline, this is the Workspace UUID.")
            var firstID: String
            @Argument(help: "Workspace UUID when the Timeline UUID is positional.")
            var secondID: String?
            @Option(name: .customLong("timeline"), help: "Timeline UUID.")
            var timelineOption: String?
            @Option(name: .customLong("network"), help: "Network Workspace URI; omit for a local Workspace.")
            var networkURI: String?

            func run() async throws {
                let timelineID = timelineOption ?? secondID.map { _ in firstID }
                let workspaceID = timelineID == nil ? secondID : firstID
                guard let timelineID, let workspaceID else {
                    throw ValidationError("Provide a Timeline UUID and Workspace UUID.")
                }
                try ConfigCommandLogic.attachWorkspace(
                    timelineID: timelineID, workspaceID: workspaceID, networkURI: networkURI,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct DetachWorkspace: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "detach-workspace", abstract: "Detach a Workspace from a Timeline.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Timeline UUID, followed by Workspace UUID; with --timeline, this is the Workspace UUID.")
            var firstID: String
            @Argument(help: "Workspace UUID when the Timeline UUID is positional.")
            var secondID: String?
            @Option(name: .customLong("timeline"), help: "Timeline UUID.")
            var timelineOption: String?

            func run() async throws {
                let timelineID = timelineOption ?? secondID.map { _ in firstID }
                let workspaceID = timelineID == nil ? secondID : firstID
                guard let timelineID, let workspaceID else {
                    throw ValidationError("Provide a Timeline UUID and Workspace UUID.")
                }
                try ConfigCommandLogic.detachWorkspace(
                    timelineID: timelineID, workspaceID: workspaceID,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }
    }

    struct Workspace: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "workspace",
            abstract: "Manage local echo Workspaces.",
            subcommands: [WorkspaceAdd.self, WorkspaceUpdate.self, WorkspaceRemove.self]
        )

        struct WorkspaceAdd: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an echo Workspace.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument(help: "Workspace name (also accepted as --name).")
            var nameArgument: String?
            @Option(name: .long) var name: String?
            @Option(name: .long, help: "Workspace URI.")
            var uri: String

            func run() async throws {
                try ConfigCommandLogic.addWorkspace(
                    name: name ?? nameArgument, uri: uri,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct WorkspaceUpdate: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a Workspace without changing its ID or kind.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument var id: String
            @Option(name: .long) var name: String?
            @Option(name: .long) var uri: String?

            func run() async throws {
                try ConfigCommandLogic.updateWorkspace(
                    id: id, name: name, uri: uri,
                    store: ConfigCommandLogic.store(for: configPath)
                )
            }
        }

        struct WorkspaceRemove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a Workspace that has no local attachments.")
            @Option(name: .customLong("config"), help: "Path to the Node manifest (overrides GNOSTIC_CONFIG).")
            var configPath: String?
            @Argument var id: String

            func run() async throws {
                try ConfigCommandLogic.removeWorkspace(id: id, store: ConfigCommandLogic.store(for: configPath))
            }
        }
    }

}

/// Testable logic behind the resource commands.
public enum ConfigCommandLogic {
    public static func store(for configPath: String?) -> CLIConfigurationStore {
        if configPath == nil {
            // ArgumentParser permits a parent option before a subcommand.
            // Leaf commands normally receive their own value, while this
            // fallback keeps the parent-option spelling equivalent.
            let arguments = Array(CommandLine.arguments.dropFirst())
            if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
                return CLIConfigurationStore(configPath: arguments[index + 1])
            }
            if let inline = arguments.first(where: { $0.hasPrefix("--config=") }) {
                return CLIConfigurationStore(configPath: String(inline.dropFirst("--config=".count)))
            }
        }
        return CLIConfigurationStore(configPath: configPath.map(URL.init(fileURLWithPath:)))
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
        try store.loadManifest().validate()
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
        _ = try store.mutateManifest { $0.broker.password = password }
    }

    public static func configurePositronic(
        ascendantID: String,
        provider: String?,
        endpoint: String?,
        model: String?,
        utilityModel: String?,
        fastModel: String?,
        store: CLIConfigurationStore
    ) throws {
        guard provider != nil || endpoint != nil || model != nil || utilityModel != nil || fastModel != nil else {
            throw CLIConfigurationError.invalidArgument("Provide at least one Positronic backend field to set.")
        }
        if let provider, provider.isEmpty {
            throw CLIConfigurationError.invalidArgument("A Positronic provider cannot be empty.")
        }
        let id = try parseID(ascendantID, kind: "ascendant")
        _ = try store.mutateManifest { manifest in
            let index = try positronicIndex(id, in: manifest)
            let configuration = PositronicBackendConfiguration(
                provider: provider, endpoint: endpoint, model: model,
                utilityModel: utilityModel, fastModel: fastModel
            )
            manifest.ascendants[index].backend = configuration.applying(to: manifest.ascendants[index].backend)
        }
    }

    public static func setPositronicAPIKey(id: String, value: String, store: CLIConfigurationStore) throws {
        let ascendantID = try parseID(id, kind: "ascendant")
        _ = try store.mutateManifest { manifest in
            let index = try positronicIndex(ascendantID, in: manifest)
            manifest.ascendants[index].backend = PositronicBackendConfiguration(apiKey: value)
                .applying(to: manifest.ascendants[index].backend)
        }
    }

    public static func clearPositronic(ascendantID: String, store: CLIConfigurationStore) throws {
        let id = try parseID(ascendantID, kind: "ascendant")
        _ = try store.mutateManifest { manifest in
            let index = try positronicIndex(id, in: manifest)
            manifest.ascendants[index].backend = .init(kind: "positronic")
        }
    }

    public static func addAscendant(name: String?, description: String, store: CLIConfigurationStore) throws {
        guard let name, !name.isEmpty else { throw CLIConfigurationError.invalidArgument("An Ascendant name is required.") }
        let ascendantID = UUID.makeVersion4()
        let timelineID = UUID.makeVersion4()
        _ = try store.mutateManifest { manifest in
            manifest.ascendants.append(.init(id: ascendantID, name: name, defaultTimelineID: timelineID, description: description, backend: .init(kind: "positronic")))
            manifest.timelines.append(.init(id: timelineID, title: "\(name) Timeline", operatingAscendantID: ascendantID))
        }
        printID("Added ascendant", ascendantID)
        printID("Added default timeline", timelineID)
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

    public static func addTimeline(title: String?, operatingAscendantID: String?, store: CLIConfigurationStore) throws {
        guard let title, !title.isEmpty else { throw CLIConfigurationError.invalidArgument("A Timeline title is required.") }
        let timelineID = UUID.makeVersion4()
        let ascendantID = try operatingAscendantID.map { try parseID($0, kind: "ascendant") }
        _ = try store.mutateManifest { manifest in
            if let ascendantID, !manifest.ascendants.contains(where: { $0.id == ascendantID }) { throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: ascendantID) }
            manifest.timelines.append(.init(id: timelineID, title: title, operatingAscendantID: ascendantID))
        }
        printID("Added timeline", timelineID)
    }

    public static func updateTimeline(
        id: String,
        title: String?,
        operatingAscendantID: String?,
        clearOperatingAscendant: Bool = false,
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

    public static func addWorkspace(name: String?, uri: String, store: CLIConfigurationStore) throws {
        guard let name, !name.isEmpty else { throw CLIConfigurationError.invalidArgument("A Workspace name is required.") }
        let workspaceID = UUID.makeVersion4()
        _ = try store.mutateManifest { $0.workspaces.append(.init(id: workspaceID, name: name, uri: uri)) }
        printID("Added workspace", workspaceID)
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

    private static func positronicIndex(_ id: UUID, in manifest: NodeManifest) throws -> Int {
        guard let index = manifest.ascendants.firstIndex(where: { $0.id == id }) else {
            throw CLIConfigurationError.resourceNotFound(kind: "ascendant", id: id)
        }
        guard manifest.ascendants[index].backend.kind == "positronic" else {
            throw CLIConfigurationError.invalidArgument("Ascendant \(id.uuidString.lowercased()) does not use the Positronic backend.")
        }
        return index
    }

    private static func printID(_ label: String, _ id: UUID) {
        print("\(label): \(id.uuidString.lowercased())")
    }

    private static func initializationSummary(_ manifest: NodeManifest) -> String {
        [
            "Initialized configuration.",
            "node: \(manifest.node.id.uuidString.lowercased())",
            "ascendant: \(manifest.ascendants[0].id.uuidString.lowercased())",
            "timeline: \(manifest.timelines[0].id.uuidString.lowercased())",
            "workspace: \(manifest.workspaces[0].id.uuidString.lowercased())",
        ].joined(separator: "\n")
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
            if ascendant.backend.kind == "positronic" {
                let configuration = PositronicBackendConfiguration(backend: ascendant.backend)
                if let provider = configuration.provider { lines.append("  backend.provider = \(provider)") }
                if let endpoint = configuration.endpoint { lines.append("  backend.endpoint = \(endpoint)") }
                if let model = configuration.model { lines.append("  backend.model = \(model)") }
                if let utilityModel = configuration.utilityModel { lines.append("  backend.utilityModel = \(utilityModel)") }
                if let fastModel = configuration.fastModel { lines.append("  backend.fastModel = \(fastModel)") }
                if configuration.apiKey != nil { lines.append("  backend.apiKey = <redacted>") }
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
