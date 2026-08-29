// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A process-safe, atomically persisted manifest store.
public struct CLIConfigurationStore: Sendable {
    static let defaultFileName = "config.json"

    public let baseDirectory: URL
    private let explicitConfigURL: URL?
    public let environment: [String: String]

    /// Creates a store. An explicit config path wins over `GNOSTIC_CONFIG`.
    public init(
        baseDirectory: URL? = nil,
        configPath: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let configPath {
            self.baseDirectory = configPath.deletingLastPathComponent()
            self.explicitConfigURL = configPath
        } else if let baseDirectory {
            self.baseDirectory = baseDirectory
            self.explicitConfigURL = nil
        } else if let custom = environment["GNOSTIC_CONFIG"], !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            self.baseDirectory = url.deletingLastPathComponent()
            self.explicitConfigURL = url
        } else {
            self.baseDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gnostic", isDirectory: true)
            self.explicitConfigURL = nil
        }
        self.environment = environment
    }

    /// Compatibility spelling for callers that model the command-line flag as an explicit path.
    public init(explicitPath: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(configPath: explicitPath, environment: environment)
    }

    public init(path: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(configPath: path, environment: environment)
    }

    public init(configPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(configPath: URL(fileURLWithPath: configPath), environment: environment)
    }

    public init(explicitPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(configPath: URL(fileURLWithPath: explicitPath), environment: environment)
    }

    public func path() -> URL {
        explicitConfigURL ?? baseDirectory.appendingPathComponent(Self.defaultFileName)
    }

    /// The retained copy of a flat file after successful migration.
    public func legacyBackupPath() -> URL {
        path().appendingPathExtension("legacy")
    }

    /// Loads the current manifest, migrating a valid flat file exactly once.
    public func loadManifest() throws -> NodeManifest {
        guard FileManager.default.fileExists(atPath: path().path) else {
            throw CLIConfigurationError.missingFile(path())
        }
        return try ManifestStoreLock.withLock(at: path()) {
            guard let manifest = try loadManifestUnlocked() else { throw CLIConfigurationError.missingFile(path()) }
            return manifest
        }
    }

    /// Creates the default resource graph, refusing to replace any existing
    /// file (including an empty or malformed one).
    @discardableResult
    public func initializeManifest() throws -> NodeManifest {
        try ManifestStoreLock.withLock(at: path()) {
            guard !FileManager.default.fileExists(atPath: path().path) else {
                throw CLIConfigurationError.fileAlreadyExists(path())
            }
            let manifest = NodeManifest.makeDefault(broker: defaultBroker)
            try manifest.validate()
            try writeManifestUnlocked(manifest)
            return manifest
        }
    }

    /// Mutates the manifest under the same lock used for reads and atomically replaces the file.
    @discardableResult
    public func mutateManifest(_ mutation: (inout NodeManifest) throws -> Void) throws -> NodeManifest {
        try ManifestStoreLock.withLock(at: path()) {
            var manifest = try existingManifestOrEmptyUnlocked()
            let original = manifest
            try mutation(&manifest)
            try manifest.validate(against: original)
            try writeManifestUnlocked(manifest)
            return manifest
        }
    }

    /// Loads the effective compatibility configuration with environment overrides.
    public func load() throws -> CLIConfiguration {
        guard FileManager.default.fileExists(atPath: path().path) else {
            return try applyEnvironmentOverrides(to: .defaults)
        }
        if let data = try? Data(contentsOf: path()), data.isEmpty {
            return try applyEnvironmentOverrides(to: .defaults)
        }
        return try effectiveConfiguration(for: loadManifest())
    }

    /// Derives compatibility settings from an already-loaded manifest snapshot.
    ///
    /// Commands that need both the resource graph and the legacy broker
    /// overrides use this to avoid reading the manifest a second time.
    public func effectiveConfiguration(for manifest: NodeManifest) throws -> CLIConfiguration {
        try applyEnvironmentOverrides(to: configuration(from: manifest))
    }

    private func applyEnvironmentOverrides(to initial: CLIConfiguration) throws -> CLIConfiguration {
        var configuration = initial
        for key in ConfigurationKey.allCases {
            guard let variable = key.environmentVariable, let value = environment[variable] else { continue }
            configuration = try configuration.setting(value, for: key)
        }
        return configuration
    }

    /// Sets a broker compatibility key in the manifest, preserving all unrelated graph data.
    /// Positronic fields require an explicitly selected Ascendant through
    /// `config positronic` and cannot be mutated through this compatibility API.
    public func setValue(_ value: String, for key: ConfigurationKey) throws {
        switch key {
        case .llmProvider, .llmEndpoint, .llmModel, .llmUtilityModel, .llmFastModel, .llmAPIKey:
            throw CLIConfigurationError.invalidArgument("Use `gnostic config positronic` with an explicit Ascendant ID.")
        default:
            break
        }
        let validated = try key.validatedValue(value)
        try ManifestStoreLock.withLock(at: path()) {
            var manifest = try existingManifestOrEmptyUnlocked()
            var configuration = configuration(from: manifest)
            configuration = try configuration.setting(validated, for: key)
            manifest = try manifestApplying(configuration, to: manifest)
            try manifest.validate()
            try writeManifestUnlocked(manifest)
        }
    }

    public func redactedDescription(for configuration: CLIConfiguration) -> String {
        configuration.redactedDescription()
    }

    public func redactedDescription(for manifest: NodeManifest) -> String {
        manifest.redactedDescription()
    }

    private func loadManifestUnlocked() throws -> NodeManifest? {
        let url = path()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw CLIConfigurationError.malformedFile(url) }
        if data.isEmpty {
            throw CLIConfigurationError.malformedFile(url)
        }

        let jsonObject = try? JSONSerialization.jsonObject(with: data)
        let object = jsonObject as? [String: Any]
        let hasSchemaVersion = object?["schemaVersion"] != nil
        if hasSchemaVersion {
            do {
                let manifest = try JSONDecoder().decode(NodeManifest.self, from: data)
                if manifest.schemaVersion == 1 {
                    let migrated = try manifest.migratedToV2()
                    try retainLegacyBackupUnlocked(data)
                    try writeManifestUnlocked(migrated)
                    return migrated
                }
                let canonical = canonicalV2Manifest(manifest)
                try canonical.validate()
                if canonical != manifest {
                    try writeManifestUnlocked(canonical)
                }
                return canonical
            } catch let error as NodeManifestError {
                throw CLIConfigurationError.invalidManifest(error, url)
            } catch {
                throw CLIConfigurationError.malformedFile(url)
            }
        }

        guard let object,
              !object.isEmpty,
              Set(object.keys).isSubset(of: PersistedConfiguration.acceptedKeys)
        else {
            throw CLIConfigurationError.malformedFile(url)
        }

        let legacy: PersistedConfiguration
        do { legacy = try JSONDecoder().decode(PersistedConfiguration.self, from: data) }
        catch { throw CLIConfigurationError.malformedFile(url) }
        let configuration = legacy.applying(.defaults)
        let manifest = Self.manifest(from: legacy, configuration: configuration)
        do { try manifest.validate() }
        catch let error as NodeManifestError { throw CLIConfigurationError.invalidManifest(error, url) }
        catch { throw CLIConfigurationError.malformedFile(url) }

        try retainLegacyBackupUnlocked(data)
        try writeManifestUnlocked(manifest)
        return manifest
    }

    private func existingManifestOrEmptyUnlocked() throws -> NodeManifest {
        if FileManager.default.fileExists(atPath: path().path) {
            let data = try Data(contentsOf: path())
            if data.isEmpty { throw CLIConfigurationError.malformedFile(path()) }
        }
        return try loadManifestUnlocked() ?? NodeManifest.empty(broker: defaultBroker)
    }

    /// Removes the retired profile identity marker from v2 files emitted by
    /// the pre-164 CLI projection without changing opaque backend settings.
    private func canonicalV2Manifest(_ manifest: NodeManifest) -> NodeManifest {
        var result = manifest
        for index in result.ascendants.indices where result.ascendants[index].backend.kind == "positronic" {
            result.ascendants[index].backend.settings.removeValue(forKey: "_legacyID")
        }
        return result
    }

    private var defaultBroker: NodeManifest.Broker {
        .init(host: CLIConfiguration.defaults.mqttHost, port: CLIConfiguration.defaults.mqttPort, namespace: CLIConfiguration.defaults.mqttNamespace)
    }

    private func retainLegacyBackupUnlocked(_ data: Data) throws {
        let backup = legacyBackupPath()
        if FileManager.default.fileExists(atPath: backup.path) { return }
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = backup.deletingLastPathComponent().appendingPathComponent(".legacy-\(UUID.makeVersion4().uuidString).tmp")
        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: backup)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CLIConfigurationError.writeFailed(backup)
        }
    }

    private func writeManifestUnlocked(_ manifest: NodeManifest) throws {
        let url = path()
        do {
            let directory = url.deletingLastPathComponent()
            let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !directoryExisted {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID.makeVersion4().uuidString).tmp")
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CLIConfigurationError.writeFailed(url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw CLIConfigurationError.writeFailed(url)
        }
    }

    private func configuration(from manifest: NodeManifest) -> CLIConfiguration {
        var result = CLIConfiguration(
            mqttHost: manifest.broker.host,
            mqttPort: manifest.broker.port,
            mqttNamespace: manifest.broker.namespace,
            mqttUsername: manifest.broker.username,
            mqttPassword: manifest.broker.password,
            llmProvider: nil,
            llmEndpoint: nil,
            llmModel: nil,
            llmUtilityModel: nil,
            llmFastModel: nil,
            llmAPIKey: nil
        )
        if let ascendant = manifest.ascendants.first(where: { $0.backend.kind == "positronic" }) {
            let configuration = PositronicBackendConfiguration(backend: ascendant.backend)
            result.llmProvider = configuration.provider
            result.llmEndpoint = configuration.endpoint
            result.llmModel = configuration.model
            result.llmUtilityModel = configuration.utilityModel
            result.llmFastModel = configuration.fastModel
            result.llmAPIKey = configuration.apiKey
        }
        return result
    }

    private func manifestApplying(_ configuration: CLIConfiguration, to manifest: NodeManifest) throws -> NodeManifest {
        var result = manifest
        result.broker = .init(host: configuration.mqttHost, port: configuration.mqttPort, namespace: configuration.mqttNamespace, username: configuration.mqttUsername, password: configuration.mqttPassword)
        return result
    }

    private static func manifest(from legacy: PersistedConfiguration, configuration: CLIConfiguration) -> NodeManifest {
        let broker = NodeManifest.Broker(host: configuration.mqttHost, port: configuration.mqttPort, namespace: configuration.mqttNamespace, username: configuration.mqttUsername, password: configuration.mqttPassword)
        let hasLLMValues = [legacy.llmProvider, legacy.llmEndpoint, legacy.llmModel, legacy.llmUtilityModel, legacy.llmFastModel, legacy.llmAPIKey].contains { $0 != nil }
        let timelineID = UUID.makeVersion4()
        let ascendantID = UUID.makeVersion4()
        let backend = hasLLMValues ? PositronicBackendConfiguration(
            provider: configuration.llmProvider ?? "positronic",
            endpoint: configuration.llmEndpoint,
            model: configuration.llmModel,
            utilityModel: configuration.llmUtilityModel,
            fastModel: configuration.llmFastModel,
            apiKey: configuration.llmAPIKey
        ).applying() : .init(kind: "positronic")
        return NodeManifest(
            broker: broker,
            node: .init(id: UUID.makeVersion4()),
            ascendants: [.init(id: ascendantID, name: "Migrated Ascendant", defaultTimelineID: timelineID, backend: backend)],
            timelines: [.init(id: timelineID, title: "Default Timeline", operatingAscendantID: ascendantID)],
            workspaces: [.init(id: UUID.makeVersion4(), name: "Echo Workspace", uri: "echo://default")]
        )
    }
}

private enum ManifestStoreLock {
    static func withLock<T>(at file: URL, _ operation: () throws -> T) throws -> T {
        let directory = file.deletingLastPathComponent()
        let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !directoryExisted {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let lockURL = directory.appendingPathComponent(".\(file.lastPathComponent).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CLIConfigurationError.writeFailed(lockURL) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CLIConfigurationError.writeFailed(lockURL) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

public typealias NodeManifestStore = CLIConfigurationStore
