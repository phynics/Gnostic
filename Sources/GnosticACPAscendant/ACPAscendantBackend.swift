// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ACP
import Foundation
import GnosticCore

/// An optional backend configuration surface for an external ACP agent.
///
/// This target currently validates and projects configuration only. It does not
/// connect to an agent; ACP Turn execution is delivered separately.
@MainActor
public final class ACPAscendantBackend: AscendantBackend {
    /// The manifest backend kind served by this implementation.
    public nonisolated static let kind = "acp-client"

    /// The configuration keys accepted by the ACP client backend.
    public nonisolated static let settingsSchema = AscendantBackendSettingsSchema(keys: [
        .init(name: "command", summary: "Executable command used to start the ACP agent."),
        .init(name: "args", summary: "Command-line arguments encoded as a JSON string array."),
        .init(name: "cwd", summary: "Optional working directory for the ACP agent process."),
        .init(name: "env", summary: "Optional JSON object of non-secret environment-variable strings."),
        .init(name: "displayName", summary: "Optional display name for the external ACP agent."),
    ], keyFamilies: [
        .init(prefix: "env.", summary: "One non-secret process environment variable."),
        .init(prefix: "env-secret.", summary: "One secret process environment variable.", isSecret: true),
    ])

    /// Gnostic-owned identity for the Ascendant served by this backend.
    public let identity: AscendantBackendIdentity

    /// Parsed process settings. This value does not start a process.
    public let launchSpec: ACPLaunchSpec

    private let configuration: AscendantBackendConfiguration
    private var timelines: [UUID: AscendantBackendTimeline]
    private var timelineOrder: [UUID]

    /// Creates the ACP backend and projects its configured Gnostic Timelines.
    ///
    /// - Parameters:
    ///   - ascendant: The manifest Ascendant served by this backend.
    ///   - configuration: The backend-owned configuration envelope.
    ///   - services: Host services, unused until ACP execution features land.
    ///   - timelines: Timelines assigned to this Ascendant in the manifest.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   envelope or launch settings are invalid.
    public init(
        ascendant: NodeManifest.Ascendant,
        configuration: AscendantBackendConfiguration,
        services _: AscendantBackendServices,
        timelines configuredTimelines: [NodeManifest.Timeline]
    ) throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        launchSpec = try Self.parse(configuration)
        self.configuration = configuration

        let now = Date()
        var projections: [UUID: AscendantBackendTimeline] = [:]
        for timeline in configuredTimelines {
            projections[timeline.id] = AscendantBackendTimeline(
                id: timeline.id,
                title: timeline.title,
                attachedWorkspaceIDs: timeline.attachments.map(\.workspaceID),
                ascendantID: ascendant.id,
                isArchived: false,
                isPrivate: timeline.id == ascendant.defaultTimelineID,
                createdAt: now,
                updatedAt: now
            )
        }
        timelines = projections
        timelineOrder = configuredTimelines.map(\.id)
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: .init(backendKind: Self.kind, backendVersion: "configuration-only")
        )
    }

    /// Revalidates the stored envelope and its process launch settings.
    public func validateConfiguration() throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        _ = try Self.parse(configuration)
    }

    /// Returns in-memory projections for manifest and runtime-created Timelines.
    ///
    /// - Returns: The ordered Timeline projections owned by this backend.
    public func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        timelineOrder.compactMap { timelines[$0] }
    }

    /// Creates an in-memory projection for one Gnostic-created Timeline.
    ///
    /// - Parameters:
    ///   - id: The Gnostic-owned Timeline identifier to adopt.
    ///   - title: The Timeline title.
    /// - Returns: The new in-memory Timeline projection.
    public func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        if let existing = timelines[id] {
            return existing
        }
        let now = Date()
        let timeline = AscendantBackendTimeline(
            id: id,
            title: title,
            attachedWorkspaceIDs: [],
            ascendantID: identity.id,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )
        timelines[id] = timeline
        timelineOrder.append(id)
        return timeline
    }

    /// Removes an in-memory Timeline projection when Gnostic removes it.
    public func removeTimeline(id: UUID) async {
        timelines.removeValue(forKey: id)
        timelineOrder.removeAll { $0 == id }
    }

    /// Renames an in-memory Timeline projection.
    ///
    /// - Parameters:
    ///   - id: The Timeline identifier to rename.
    ///   - title: The new title.
    /// - Returns: The updated in-memory Timeline projection.
    /// - Throws: ``AscendantBackendError/timelineNotFound(_:)`` when this
    ///   backend does not project the Timeline.
    public func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let current = timelines[id] else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        let renamed = AscendantBackendTimeline(
            id: current.id,
            title: title,
            attachedWorkspaceIDs: current.attachedWorkspaceIDs,
            ascendantID: current.ascendantID,
            isArchived: current.isArchived,
            isPrivate: current.isPrivate,
            createdAt: current.createdAt,
            updatedAt: Date()
        )
        timelines[id] = renamed
        return renamed
    }

    /// Fails a Turn until the ACP execution capability is implemented.
    ///
    /// - Parameters:
    ///   - request: The Timeline-addressed Turn request.
    ///   - updates: The host update sink, unused because no Turn is started.
    /// - Returns: This implementation never returns a successful Turn result.
    /// - Throws: ``AscendantBackendError/timelineNotFound(_:)`` for an unknown
    ///   Timeline or a terminal configuration failure until GNO-ACPC-003.
    public func runTurn(
        _ request: AscendantBackendTurnRequest,
        updates _: any AscendantBackendUpdateSink
    ) async throws -> String {
        guard timelines[request.timelineID] != nil else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        throw AscendantBackendError.terminal(.init(
            code: "acpTurnUnavailable",
            message: "ACP Turn execution is not available until GNO-ACPC-003.",
            retryable: false
        ))
    }

    /// Does nothing because no ACP connection is opened in this increment.
    public func cancel() async {}

    /// Releases no resources because no ACP connection is opened in this increment.
    public func shutdown() async {}

    private static func parse(_ configuration: AscendantBackendConfiguration) throws -> ACPLaunchSpec {
        guard configuration.kind == kind else {
            throw invalidConfiguration("The ACP backend requires kind '\(kind)'.")
        }
        let acceptedSettings = Set(settingsSchema.settingNames)
        if let unknown = configuration.settings.keys.sorted().first(where: {
            !acceptedSettings.contains($0) && settingsSchema.dynamicFamily(matching: $0) == nil
        }) {
            throw invalidConfiguration("The ACP backend does not accept setting '\(unknown)'.")
        }
        guard let command = stringSetting("command", in: configuration.settings),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.contains("\0") else {
            throw invalidConfiguration("The ACP backend requires a non-empty 'command' setting.")
        }

        let arguments: [String]
        if let encodedArguments = configuration.settings["args"] {
            guard case let .string(json) = encodedArguments,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                throw invalidConfiguration("The ACP backend setting 'args' must be a JSON array of strings.")
            }
            arguments = decoded
        } else {
            arguments = []
        }
        guard arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw invalidConfiguration("The ACP backend setting 'args' cannot contain null characters.")
        }

        let workingDirectory = try optionalStringSetting("cwd", in: configuration.settings)
        let displayName = try optionalStringSetting("displayName", in: configuration.settings)
        var environment: [String: String]
        if let encodedEnvironment = configuration.settings["env"] {
            guard case let .string(json) = encodedEnvironment,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw invalidConfiguration("The ACP backend setting 'env' must be a JSON object of string values.")
            }
            environment = decoded
        } else {
            environment = [:]
        }
        guard environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }) else {
            throw invalidConfiguration("The ACP backend setting 'env' contains an invalid environment-variable name or value.")
        }

        try addDynamicEnvironmentValues(
            from: configuration.settings,
            expectsSecret: false,
            to: &environment
        )
        try addDynamicEnvironmentValues(
            from: configuration.secrets,
            expectsSecret: true,
            to: &environment
        )

        return ACPLaunchSpec(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            displayName: displayName
        )
    }

    private static func stringSetting(
        _ key: String,
        in settings: [String: ManifestJSONValue]
    ) -> String? {
        guard case let .string(value)? = settings[key] else { return nil }
        return value
    }

    private static func optionalStringSetting(
        _ key: String,
        in settings: [String: ManifestJSONValue]
    ) throws -> String? {
        guard let value = settings[key] else { return nil }
        guard case let .string(string) = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !string.contains("\0") else {
            throw invalidConfiguration("The ACP backend setting '\(key)' must be a non-empty string when provided.")
        }
        return string
    }

    private static func addDynamicEnvironmentValues(
        from values: [String: ManifestJSONValue],
        expectsSecret: Bool,
        to environment: inout [String: String]
    ) throws {
        for key in values.keys.sorted() {
            guard let dynamic = settingsSchema.dynamicFamily(matching: key) else {
                if expectsSecret {
                    throw invalidConfiguration("The ACP backend does not accept secret setting '\(key)'.")
                }
                continue
            }
            guard dynamic.family.isSecret == expectsSecret else {
                throw invalidConfiguration("The ACP backend does not accept \(expectsSecret ? "secret" : "plain") setting '\(key)'.")
            }
            guard AscendantBackendSettingsSchema.isValidEnvironmentVariableName(dynamic.member) else {
                throw invalidConfiguration("The ACP backend setting '\(key)' must name a valid environment variable.")
            }
            guard case let .string(value) = values[key], !value.contains("\0") else {
                throw invalidConfiguration("The ACP backend setting '\(key)' must be a string without null characters.")
            }
            guard environment[dynamic.member] == nil else {
                throw invalidConfiguration("The ACP backend environment variable '\(dynamic.member)' is configured more than once.")
            }
            environment[dynamic.member] = value
        }
    }

    private static func invalidConfiguration(_ message: String) -> AscendantBackendError {
        .invalidConfiguration(message)
    }
}
