// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// One external prerequisite a module needs before it can run.
///
/// A prerequisite names an executable or script the host depends on. The value
/// is a fact about this machine, not about the manifest, so it is computed at
/// read time and never persisted.
public struct GnosticModulePrerequisite: Sendable, Equatable {
    /// The prerequisite name, for example `guile`.
    public let name: String
    /// The path that was checked.
    public let path: String
    /// Whether the path exists and is usable.
    public let isAvailable: Bool
    /// A remediation hint shown when the path is unavailable.
    public let hint: String

    /// Creates one prerequisite fact.
    public init(name: String, path: String, isAvailable: Bool, hint: String) {
        self.name = name
        self.path = path
        self.isAvailable = isAvailable
        self.hint = hint
    }
}

/// One compiled-in module of the Gnostic platform.
///
/// A module is selected per Ascendant through the backend-owned `extensions`
/// setting and declares the configuration it owns:
///
/// - the settings and secrets keys it reads (``settingKeys``),
/// - whether it needs a dedicated model service (``requiresModelService``),
/// - optional terminal Turn observer factories (``terminalTurnObservers``),
/// - an optional experiment subcommand (``experimentSubcommand``).
///
/// The host keeps only the clean descriptor surface. Provider-specific
/// contribution and interception factories live in the transitional legacy
/// target, so this module cannot execute PositronicKit in the host process.
///
/// The registry lives in the composition source; `GnosticCore` never depends on
/// a module. Selection is static: there is no live enable, disable, or hot
/// reload.
public struct GnosticModule: Sendable {
    /// Reports the external prerequisites a module needs for one Ascendant.
    ///
    /// - Parameter settings: The module's own settings with the module name
    ///   prefix stripped.
    /// - Returns: One fact per prerequisite path.
    public typealias PrerequisiteFactory = @Sendable ([String: String]) -> [GnosticModulePrerequisite]

    /// Builds one terminal Turn observer from the module's scoped settings.
    ///
    /// The observer is installed only for the Ascendant that selected the
    /// module. It is called once, when `serve` or the runner builds adapters.
    public typealias ObserverFactory = @Sendable (GnosticModuleScope) -> any TerminalTurnObserving

    /// The static selection name used in the `extensions` setting.
    public let name: String
    /// The `experiments.json` registry id, when the module has an entry.
    public let registryID: String?
    /// The settings keys this module understands, before name-spacing.
    public let settingKeys: [AscendantBackendSettingsSchema.Key]
    /// Whether the module needs a dedicated model service at runtime.
    public let requiresModelService: Bool
    /// The optional experiment subcommand this module owns.
    public let experimentSubcommand: GnosticModuleSubcommand?
    /// Whether the module installs a provider-specific contribution.
    ///
    /// The clean host never installs one. The flag exists so configuration
    /// listings remain honest about a descriptor that still declares one.
    public let installsContribution: Bool
    /// Builds the terminal Turn observers for one Ascendant.
    public let terminalTurnObservers: [ObserverFactory]
    /// Reports the module's external prerequisites for one Ascendant's settings.
    public let prerequisites: PrerequisiteFactory?

    /// Creates one compiled-in module.
    public init(
        name: String,
        registryID: String? = nil,
        settingKeys: [AscendantBackendSettingsSchema.Key] = [],
        requiresModelService: Bool = false,
        experimentSubcommand: GnosticModuleSubcommand? = nil,
        installsContribution: Bool = false,
        terminalTurnObservers: [ObserverFactory] = [],
        prerequisites: PrerequisiteFactory? = nil
    ) {
        precondition(
            !name.isEmpty && !name.contains("."),
            "A module name must be non-empty and must not contain '.'."
        )
        self.name = name
        self.registryID = registryID
        self.settingKeys = settingKeys
        self.requiresModelService = requiresModelService
        self.experimentSubcommand = experimentSubcommand
        self.installsContribution = installsContribution
        self.terminalTurnObservers = terminalTurnObservers
        self.prerequisites = prerequisites
    }
}

/// The subcommand one module contributes to `gnostic experiment`.
///
/// The descriptor names the subcommand and its summary. The CLI owns argument
/// parsing and rendering, so `GnosticHost` does not depend on `ArgumentParser`.
public struct GnosticModuleSubcommand: Sendable, Equatable {
    /// The subcommand name, for example `rlm-scenario`.
    public let name: String
    /// The one-line summary used in help output.
    public let abstract: String

    /// Creates one experiment subcommand descriptor.
    public init(name: String, abstract: String) {
        precondition(!name.isEmpty, "An experiment subcommand name must be non-empty.")
        self.name = name
        self.abstract = abstract
    }
}

/// The per-Ascendant configuration one selected module reads.
///
/// ``settings`` and ``secrets`` are keyed without the module's name-space
/// prefix, so a module only ever sees its own values.
public struct GnosticModuleScope: Sendable {
    /// The Ascendant selecting the module.
    public let ascendant: NodeManifest.Ascendant
    /// The module's static name.
    public let name: String
    /// The module's settings, keyed without the name-space prefix.
    public let settings: [String: ManifestJSONValue]
    /// The module's secrets, keyed without the name-space prefix.
    public let secrets: [String: ManifestJSONValue]

    /// Creates the scoped configuration for one module invocation.
    public init(
        ascendant: NodeManifest.Ascendant,
        name: String,
        settings: [String: ManifestJSONValue],
        secrets: [String: ManifestJSONValue]
    ) {
        self.ascendant = ascendant
        self.name = name
        self.settings = settings
        self.secrets = secrets
    }

    /// Reads one string setting.
    public func stringSetting(_ key: String) throws -> String? {
        try Self.string(key, in: settings, moduleName: name, isSecret: false)
    }

    /// Reads one string secret.
    public func stringSecret(_ key: String) throws -> String? {
        try Self.string(key, in: secrets, moduleName: name, isSecret: true)
    }

    private static func string(
        _ key: String,
        in values: [String: ManifestJSONValue],
        moduleName: String,
        isSecret: Bool
    ) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case let .string(text) = value else {
            let kind = isSecret ? "secret" : "setting"
            throw AscendantBackendError.invalidConfiguration(
                "Module '\(moduleName)' \(kind) '\(key)' must be a string."
            )
        }
        return text
    }
}
