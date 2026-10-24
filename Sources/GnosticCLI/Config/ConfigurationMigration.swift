// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A structured, user-safe failure from the operator configuration migration.
public struct ConfigurationMigrationError: Error, Equatable, LocalizedError, Sendable {
    public let reasonCode: String
    public let message: String
    public let remediation: String

    public init(reasonCode: String, message: String, remediation: String) {
        self.reasonCode = reasonCode
        self.message = message
        self.remediation = remediation
    }

    public var errorDescription: String? { "\(message) \(remediation)" }
}

/// A safe, structured account of the changes made or previewed by migration.
public struct ConfigurationMigrationReport: Codable, Equatable, Sendable {
    public let mode: Mode
    public let source: String
    public let backup: String?
    public let changedFields: [String]
    public let preservedNodeID: UUID
    public let preservedRuntimeInstanceIDs: [UUID]
    public let preservedTimelineIDs: [UUID]
    public let preservedWorkspaceIDs: [UUID]

    public enum Mode: String, Codable, Sendable { case dryRun, migrated }
}

/// Migrates only the immediate pre-v0.5 schema-v2 operator manifest.
public enum ConfigurationMigration {
    enum SyncPoint: Equatable {
        case backupFile
        case backupDirectory
        case replacementFile
        case replacementDirectory
    }

    private struct MigrationOperationFailure: Error {
        let underlying: Error
    }

    private static let sourceSchemaVersion = 2
    private static let supportedBackendKind = "acp-client"
    private static let acceptedACPPSettings: Set<String> = ["command", "args", "cwd", "displayName", "env", "scratchRoot"]

    /// Validates and converts the 0.4.2 manifest at `url`. Dry runs never write
    /// to the source or create a backup. Apply mode copies the exact source
    /// bytes to a new backup before atomically replacing the manifest.
    public static func migrate(at url: URL, dryRun: Bool) throws -> ConfigurationMigrationReport {
        try migrate(at: url, dryRun: dryRun, afterReadingSource: nil, beforeSync: nil)
    }

    static func migrateForTesting(
        at url: URL,
        dryRun: Bool,
        afterReadingSource: @escaping () -> Void,
        afterBackup: @escaping () -> Void = {},
        beforeSync: ((SyncPoint) throws -> Void)? = nil
    ) throws -> ConfigurationMigrationReport {
        try migrate(
            at: url,
            dryRun: dryRun,
            afterReadingSource: afterReadingSource,
            afterBackup: afterBackup,
            beforeSync: beforeSync
        )
    }

    private static func migrate(
        at url: URL,
        dryRun: Bool,
        afterReadingSource: (() -> Void)?,
        afterBackup: (() -> Void)? = nil,
        beforeSync: ((SyncPoint) throws -> Void)?
    ) throws -> ConfigurationMigrationReport {
        do {
            return try ManifestStoreLock.withLock(at: url) {
                do {
                    return try migrateLocked(
                        at: url,
                        dryRun: dryRun,
                        afterReadingSource: afterReadingSource,
                        afterBackup: afterBackup,
                        beforeSync: beforeSync
                    )
                } catch {
                    throw MigrationOperationFailure(underlying: error)
                }
            }
        } catch let failure as MigrationOperationFailure {
            throw failure.underlying
        } catch let error as ConfigurationMigrationError {
            throw error
        } catch {
            throw ConfigurationMigrationError(
                reasonCode: "configurationLockFailed",
                message: "Could not lock the configuration at '\(url.path)'.",
                remediation: "Check the configuration directory permissions, then retry."
            )
        }
    }

    private static func migrateLocked(
        at url: URL,
        dryRun: Bool,
        afterReadingSource: (() -> Void)?,
        afterBackup: (() -> Void)?,
        beforeSync: ((SyncPoint) throws -> Void)?
    ) throws -> ConfigurationMigrationReport {
        let source: Data
        do {
            source = try Data(contentsOf: url)
        } catch {
            throw ConfigurationMigrationError(
                reasonCode: "configurationReadFailed",
                message: "Could not read the configuration at '\(url.path)'.",
                remediation: "Check that the path exists and is readable, then retry."
            )
        }
        afterReadingSource?()

        let manifest = try decodeSource(source, url: url)
        try validateMappings(manifest)
        let converted = try encodeDestination(source)
        guard try Data(contentsOf: url) == source else {
            throw sourceChanged(at: url)
        }
        if !dryRun {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try rejectUnsupportedOwnership(attributes, at: url)
        }
        let backupURL = dryRun ? nil : try makeBackup(of: url, source: source, beforeSync: beforeSync)
        afterBackup?()

        if !dryRun {
            do {
                try atomicallyReplace(
                    converted,
                    at: url,
                    expectedSource: source,
                    backupURL: backupURL,
                    beforeSync: beforeSync
                )
            } catch let error as ConfigurationMigrationError {
                throw error
            } catch {
                throw ConfigurationMigrationError(
                    reasonCode: "configurationWriteFailed",
                    message: "Could not replace the configuration at '\(url.path)'; the original was not replaced.",
                    remediation: "The backup remains at '\(backupURL?.path ?? "the timestamped backup")'. Check filesystem permissions and retry."
                )
            }
        }

        return ConfigurationMigrationReport(
            mode: dryRun ? .dryRun : .migrated,
            source: url.path,
            backup: backupURL?.path,
            changedFields: [
                "ascendants → runtimeInstances",
                "timelines[].operatingAscendantID → runtimeInstanceID",
            ],
            preservedNodeID: manifest.node.id,
            preservedRuntimeInstanceIDs: manifest.ascendants.map(\.id),
            preservedTimelineIDs: manifest.timelines.map(\.id),
            preservedWorkspaceIDs: manifest.workspaces.map(\.id)
        )
    }

    private static func decodeSource(_ data: Data, url: URL) throws -> NodeManifest {
        let raw: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw invalid("The configuration root must be a JSON object.")
            }
            raw = value
        } catch let error as ConfigurationMigrationError {
            throw error
        } catch {
            throw invalid("The configuration at '\(url.path)' is not valid JSON.")
        }

        guard let version = raw["schemaVersion"] as? Int else {
            throw invalid("The configuration has no integer schemaVersion.")
        }
        guard version == sourceSchemaVersion else {
            throw ConfigurationMigrationError(
                reasonCode: "unsupportedSchemaVersion",
                message: "This command migrates only the immediate pre-v0.5 schema-v2 manifest; it found schema version \(version).",
                remediation: "Use the release tool that owns this schema version. Schema-v1 migration is not supported."
            )
        }
        guard let ascendants = raw["ascendants"] as? [[String: Any]], raw["runtimeInstances"] == nil else {
            throw ConfigurationMigrationError(
                reasonCode: "notPreV05Manifest",
                message: "The schema-v2 manifest does not have the immediate pre-v0.5 Ascendant shape.",
                remediation: "Use this command only once on an un-migrated 0.4.2 manifest."
            )
        }
        guard ascendants.allSatisfy({ $0["backend"] is [String: Any] && $0["defaultTimelineID"] != nil && $0["timelineID"] == nil }) else {
            throw ConfigurationMigrationError(
                reasonCode: "notPreV05Manifest",
                message: "The schema-v2 manifest does not use the released 0.4.2 configuration shape.",
                remediation: "Use this command only with an immediate pre-v0.5 manifest. Older configuration formats are not supported."
            )
        }
        if let timelines = raw["timelines"] as? [[String: Any]], timelines.contains(where: { $0["runtimeInstanceID"] != nil }) {
            throw ConfigurationMigrationError(
                reasonCode: "notPreV05Manifest",
                message: "The manifest already contains Runtime instance Timeline references.",
                remediation: "Do not migrate an already-converted manifest."
            )
        }

        do {
            let manifest = try JSONDecoder().decode(NodeManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch {
            throw ConfigurationMigrationError(
                reasonCode: "invalidManifest",
                message: "The schema-v2 configuration is invalid and was not changed.",
                remediation: "Correct the manifest validation error, then retry. \(error.localizedDescription)"
            )
        }
    }

    private static func validateMappings(_ manifest: NodeManifest) throws {
        // Preserve ACPAscendantBackend.parse's launch constraints here. The
        // CLI cannot construct that backend without starting its owning target.
        for instance in manifest.ascendants {
            let backendKind = instance.backend.kind
            guard instance.kind == backendKind else {
                throw ConfigurationMigrationError(
                    reasonCode: "ambiguousRuntimeMapping",
                    message: "Configuration '\(instance.name)' has conflicting kinds '\(instance.kind)' and '\(backendKind)'.",
                    remediation: "Choose and configure one ACP v2 Runtime explicitly, then rerun migration."
                )
            }
            guard backendKind == supportedBackendKind else {
                let remediation: String
                if backendKind == "positronic" || backendKind == "letta" {
                    remediation = "Install or select an ACP v2 Runtime process, configure it as a local command, and migrate again. Historical backend state is not converted."
                } else {
                    remediation = "Configure this resource as an ACP v2 Runtime process using `gnostic config ascendant add --kind acp-client`, then migrate again."
                }
                throw ConfigurationMigrationError(
                    reasonCode: "unsupportedRuntimeMapping",
                    message: "Configuration '\(instance.name)' uses removed or unsupported backend kind '\(backendKind)'.",
                    remediation: remediation
                )
            }

            guard let command = instance.backend.settings["command"]?.stringValue,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !command.contains("\0") else {
                throw ConfigurationMigrationError(
                    reasonCode: "ambiguousRuntimeMapping",
                    message: "ACP configuration '\(instance.name)' has no executable command.",
                    remediation: "Set its `command` to the ACP agent executable, then rerun migration."
                )
            }
            let unknownSettings = Set(instance.backend.settings.keys).subtracting(acceptedACPPSettings).filter { !$0.hasPrefix("env.") }
            guard unknownSettings.isEmpty else {
                throw ConfigurationMigrationError(
                    reasonCode: "ambiguousRuntimeMapping",
                    message: "ACP configuration '\(instance.name)' contains settings that cannot be mapped safely: \(unknownSettings.sorted().joined(separator: ", ")).",
                    remediation: "Move these settings into the Runtime's own configuration or remove them, then rerun migration."
                )
            }
            for (key, value) in instance.backend.settings where key.hasPrefix("env.") {
                let name = String(key.dropFirst("env.".count))
                guard AscendantBackendSettingsSchema.isValidEnvironmentVariableName(name),
                      let stringValue = value.stringValue,
                      !stringValue.contains("\0") else {
                    throw ConfigurationMigrationError(
                        reasonCode: "ambiguousRuntimeMapping",
                        message: "ACP configuration '\(instance.name)' has an invalid environment setting.",
                        remediation: "Use `env.<VARIABLE>` with a valid variable name and string value, then rerun migration."
                    )
                }
            }

            if let args = instance.backend.settings["args"] {
                guard let json = args.stringValue,
                      let data = json.data(using: .utf8),
                      let values = try? JSONDecoder().decode([String].self, from: data),
                      values.allSatisfy({ !$0.contains("\0") }) else {
                    throw ConfigurationMigrationError(
                        reasonCode: "ambiguousRuntimeMapping",
                        message: "ACP configuration '\(instance.name)' has invalid `args`.",
                        remediation: "Store `args` as a JSON array of strings, then rerun migration."
                    )
                }
            }
            var environmentNames = Set<String>()
            if let environment = instance.backend.settings["env"] {
                guard let json = environment.stringValue,
                      let data = json.data(using: .utf8),
                      let values = try? JSONDecoder().decode([String: String].self, from: data),
                      values.allSatisfy({ AscendantBackendSettingsSchema.isValidEnvironmentVariableName($0.key) && !$0.value.contains("\0") }) else {
                    throw ConfigurationMigrationError(
                        reasonCode: "ambiguousRuntimeMapping",
                        message: "ACP configuration '\(instance.name)' has invalid `env`.",
                        remediation: "Store `env` as a JSON object of string values, then rerun migration."
                    )
                }
                environmentNames = Set(values.keys)
            }
            for key in ["cwd", "displayName"] where instance.backend.settings[key] != nil {
                guard let value = instance.backend.settings[key]?.stringValue,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !value.contains("\0") else {
                    throw ConfigurationMigrationError(
                        reasonCode: "ambiguousRuntimeMapping",
                        message: "ACP configuration '\(instance.name)' has an invalid `\(key)` setting.",
                        remediation: "Set `\(key)` to a string value, then rerun migration."
                    )
                }
            }
            if let scratchRoot = instance.backend.settings["scratchRoot"] {
                guard let value = scratchRoot.stringValue,
                      value.hasPrefix("/"),
                      !value.contains("\0") else {
                    throw ConfigurationMigrationError(
                        reasonCode: "ambiguousRuntimeMapping",
                        message: "ACP configuration '\(instance.name)' has an invalid `scratchRoot` setting.",
                        remediation: "Set `scratchRoot` to an absolute directory path, then rerun migration."
                    )
                }
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), !isDirectory.boolValue {
                    throw ConfigurationMigrationError(
                        reasonCode: "ambiguousRuntimeMapping",
                        message: "ACP configuration '\(instance.name)' has an invalid `scratchRoot` setting.",
                        remediation: "Set `scratchRoot` to an absolute directory path, then rerun migration."
                    )
                }
            }
            let unknownSecrets = instance.backend.secrets.keys.filter { !$0.hasPrefix("env-secret.") }
            guard unknownSecrets.isEmpty else {
                throw ConfigurationMigrationError(
                    reasonCode: "ambiguousRuntimeMapping",
                    message: "ACP configuration '\(instance.name)' contains secret settings that cannot be mapped safely.",
                    remediation: "Move credentials to `env-secret.<VARIABLE>` settings, then rerun migration."
                )
            }
            for key in instance.backend.secrets.keys {
                let name = String(key.dropFirst("env-secret.".count))
                guard !name.isEmpty,
                      AscendantBackendSettingsSchema.isValidEnvironmentVariableName(name),
                      let value = instance.backend.secrets[key]?.stringValue,
                      !value.contains("\0") else {
                throw ConfigurationMigrationError(
                    reasonCode: "ambiguousRuntimeMapping",
                    message: "ACP configuration '\(instance.name)' has an invalid environment secret setting.",
                    remediation: "Use a non-empty `env-secret.<VARIABLE>` name with a string value, then rerun migration."
                )
                }
            }
            let plainNames = Set(instance.backend.settings.keys.compactMap { key -> String? in
                guard key.hasPrefix("env.") else { return nil }
                return String(key.dropFirst("env.".count))
            })
            let secretNames = Set(instance.backend.secrets.keys.compactMap { key -> String? in
                guard key.hasPrefix("env-secret.") else { return nil }
                return String(key.dropFirst("env-secret.".count))
            })
            if !plainNames.isDisjoint(with: secretNames)
                || !plainNames.isDisjoint(with: environmentNames)
                || !secretNames.isDisjoint(with: environmentNames) {
                throw invalidEnvironmentMapping(instance.name)
            }
        }
    }

    private static func encodeDestination(_ source: Data) throws -> Data {
        do {
            guard var destination = try JSONSerialization.jsonObject(with: source) as? [String: Any],
                  let runtimeInstances = destination.removeValue(forKey: "ascendants") as? [[String: Any]] else {
                throw invalid("The validated manifest could not be converted to Runtime instance configuration.")
            }
            destination["runtimeInstances"] = runtimeInstances

            if var timelines = destination["timelines"] as? [[String: Any]] {
                for index in timelines.indices {
                    if let runtimeInstanceID = timelines[index].removeValue(forKey: "operatingAscendantID") {
                        timelines[index]["runtimeInstanceID"] = runtimeInstanceID
                    }
                }
                destination["timelines"] = timelines
            }

            let data = try JSONSerialization.data(withJSONObject: destination, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let migrated = try JSONDecoder().decode(NodeManifest.self, from: data)
            try migrated.validate()
            return data
        } catch {
            throw ConfigurationMigrationError(
                reasonCode: "migrationEncodingFailed",
                message: "The validated configuration could not be encoded in the v0.5 manifest shape.",
                remediation: "Keep the source file and report this error before retrying."
            )
        }
    }

    private static func makeBackup(
        of sourceURL: URL,
        source: Data,
        beforeSync: ((SyncPoint) throws -> Void)?
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let backupURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            "\(sourceURL.lastPathComponent).pre-v0.5-\(formatter.string(from: Date())).bak"
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: backupURL)
            guard try Data(contentsOf: backupURL) == source else {
                throw CocoaError(.fileWriteUnknown)
            }
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            try preserveOwnership(from: sourceAttributes, on: backupURL)
            if let mode = sourceAttributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: backupURL.path)
            }
            guard try Data(contentsOf: backupURL) == source,
                  try FileManager.default.attributesOfItem(atPath: backupURL.path)[.ownerAccountID] as? NSNumber
                    == sourceAttributes[.ownerAccountID] as? NSNumber,
                  try FileManager.default.attributesOfItem(atPath: backupURL.path)[.groupOwnerAccountID] as? NSNumber
                    == sourceAttributes[.groupOwnerAccountID] as? NSNumber else {
                throw CocoaError(.fileWriteUnknown)
            }
            let descriptor = open(backupURL.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = close(descriptor) }
            try beforeSync?(.backupFile)
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try syncParentDirectory(of: sourceURL, point: .backupDirectory, beforeSync: beforeSync)
            return backupURL
        } catch {
            throw ConfigurationMigrationError(
                reasonCode: "backupCreationFailed",
                message: "Could not create a timestamped backup beside '\(sourceURL.path)'.",
                remediation: "The source was not changed. Any backup created at '\(backupURL.path)' was retained; run as the configuration owner or check ownership, directory permissions, and available disk space, then retry."
            )
        }
    }

    private static func atomicallyReplace(
        _ data: Data,
        at destination: URL,
        expectedSource: Data,
        backupURL: URL?,
        beforeSync: ((SyncPoint) throws -> Void)?
    ) throws {
        let manager = FileManager.default
        let originalAttributes = try manager.attributesOfItem(atPath: destination.path)
        try rejectUnsupportedOwnership(originalAttributes, at: destination)
        let mode = originalAttributes[.posixPermissions] as? NSNumber
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).migration-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }

        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        try preserveOwnership(from: originalAttributes, descriptor: descriptor)
        if let mode, fchmod(descriptor, mode.uint32Value) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try beforeSync?(.replacementFile)
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard try Data(contentsOf: destination) == expectedSource else {
            throw sourceChanged(at: destination)
        }
        let result = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try syncParentDirectory(of: destination, point: .replacementDirectory, beforeSync: beforeSync)
        } catch {
            throw ConfigurationMigrationError(
                reasonCode: "replacementDurabilityUnconfirmed",
                message: "The migrated configuration is visible at '\(destination.path)', but its directory sync failed.",
                remediation: "Do not assume the replacement is durable after a power loss. The original backup remains at '\(backupURL?.path ?? "the timestamped backup")'. Check the filesystem and keep both files for recovery."
            )
        }
    }

    private static func preserveOwnership(from attributes: [FileAttributeKey: Any], on url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        try preserveOwnership(from: attributes, descriptor: descriptor)
    }

    private static func rejectUnsupportedOwnership(_ attributes: [FileAttributeKey: Any], at url: URL) throws {
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value != geteuid(), geteuid() != 0 else { return }
        throw ConfigurationMigrationError(
            reasonCode: "configurationOwnershipUnsupported",
            message: "Cannot preserve the owner of '\(url.path)' when replacing it.",
            remediation: "Run migration as the configuration owner or with permission to preserve its ownership. The source was not changed."
        )
    }

    private static func preserveOwnership(from attributes: [FileAttributeKey: Any], descriptor: Int32) throws {
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              let group = attributes[.groupOwnerAccountID] as? NSNumber else { return }
        guard fchown(descriptor, uid_t(owner.uint32Value), gid_t(group.uint32Value)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func syncParentDirectory(
        of url: URL,
        point: SyncPoint,
        beforeSync: ((SyncPoint) throws -> Void)?
    ) throws {
        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        try beforeSync?(point)
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func invalidEnvironmentMapping(_ name: String) -> ConfigurationMigrationError {
        ConfigurationMigrationError(
            reasonCode: "ambiguousRuntimeMapping",
            message: "ACP configuration '\(name)' defines one environment variable more than once.",
            remediation: "Configure each environment variable in only one of `env`, `env.<VARIABLE>`, or `env-secret.<VARIABLE>`, then rerun migration."
        )
    }

    private static func sourceChanged(at url: URL) -> ConfigurationMigrationError {
        ConfigurationMigrationError(
            reasonCode: "configurationChangedDuringMigration",
            message: "The configuration at '\(url.path)' changed while migration was preparing it.",
            remediation: "No converted file was written. Review the latest configuration and rerun migration."
        )
    }

    private static func invalid(_ detail: String) -> ConfigurationMigrationError {
        ConfigurationMigrationError(
            reasonCode: "invalidMigrationInput",
            message: detail,
            remediation: "Provide an unmodified 0.4.2 schema-v2 manifest and retry."
        )
    }
}
