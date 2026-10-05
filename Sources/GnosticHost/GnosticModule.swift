// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// One compiled-in module of the Gnostic platform.
///
/// A module is selected per Ascendant through the backend-owned `extensions`
/// setting and declares everything the selection turns on:
///
/// - the settings and secrets keys it reads (``settingKeys``),
/// - whether it needs a dedicated model service (``requiresModelService``),
/// - an optional Positronic contribution factory (``contribution``),
/// - optional terminal Turn observer factories (``terminalTurnObservers``),
/// - an optional experiment subcommand (``experimentSubcommand``).
///
/// The registry lives in the composition source; `GnosticCore` never depends on
/// a module. Two Ascendants on one Node may select different module sets.
/// Selection is static: there is no live enable, disable, or hot reload.
///
/// A module's own keys are namespaced by its name in the Positronic schema
/// (`<name>.<key>`), so two modules can declare the same key without colliding.
/// Secrets are namespaced the same way in `backend.secrets`, which keeps them
/// covered by the existing structural redaction.
public struct GnosticModule: Sendable {
    /// Builds one Positronic contribution from the module's scoped settings.
    ///
    /// - Parameter scope: The Ascendant and the module's own settings.
    /// - Returns: The contribution the adapter installs.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   module's settings are missing or malformed.
    public typealias ContributionFactory = @Sendable (GnosticModuleScope) throws -> any PositronicContribution

    /// Builds one terminal Turn observer from the module's scoped settings.
    ///
    /// The observer is installed only for the Ascendant that selected the
    /// module. It is called once, when `serve` or the runner builds adapters.
    /// It cannot throw: validate settings in ``contribution``, whose failure
    /// aborts startup before advertisement.
    ///
    /// - Parameter scope: The Ascendant and the module's own settings.
    /// - Returns: The observer the runtime installs.
    public typealias ObserverFactory = @Sendable (GnosticModuleScope) -> any TerminalTurnObserving

    /// The static selection name used in the `extensions` setting.
    public let name: String
    /// The `experiments.json` registry id, when the module has an entry.
    ///
    /// `make docs-check` rejects a descriptor that names an id with no
    /// matching registry entry.
    public let registryID: String?
    /// The settings keys this module understands, before name-spacing.
    public let settingKeys: [AscendantBackendSettingsSchema.Key]
    /// Whether the module needs a dedicated model service at runtime.
    public let requiresModelService: Bool
    /// The optional experiment subcommand this module owns.
    public let experimentSubcommand: GnosticModuleSubcommand?
    /// Builds the terminal Turn observers for one Ascendant.
    public let terminalTurnObservers: [ObserverFactory]
    /// Builds the Positronic contribution for one Ascendant, when it has one.
    public let contribution: ContributionFactory?

    /// Creates one compiled-in module.
    ///
    /// - Parameters:
    ///   - name: The static selection name. It must not be empty.
    ///   - registryID: The optional `experiments.json` registry id.
    ///   - settingKeys: The module's own keys, prefixed with `name` in the
    ///     Positronic schema.
    ///   - requiresModelService: Whether a dedicated model service is needed.
    ///   - experimentSubcommand: The optional experiment subcommand.
    ///   - terminalTurnObservers: Builds the terminal Turn observers.
    ///   - contribution: Builds the Positronic contribution.
    public init(
        name: String,
        registryID: String? = nil,
        settingKeys: [AscendantBackendSettingsSchema.Key] = [],
        requiresModelService: Bool = false,
        experimentSubcommand: GnosticModuleSubcommand? = nil,
        terminalTurnObservers: [ObserverFactory] = [],
        contribution: ContributionFactory? = nil
    ) {
        // Scoping strips the `"\(name)."` prefix from an envelope, so a dot in
        // `name` would let one module read another's settings. Module names are
        // compiled in, so this is a composition-time programming error rather
        // than untrusted input.
        precondition(
            !name.isEmpty && !name.contains("."),
            "A module name must be non-empty and must not contain '.'."
        )
        self.name = name
        self.registryID = registryID
        self.settingKeys = settingKeys
        self.requiresModelService = requiresModelService
        self.experimentSubcommand = experimentSubcommand
        self.terminalTurnObservers = terminalTurnObservers
        self.contribution = contribution
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
    ///
    /// - Parameters:
    ///   - name: The subcommand name. It must not be empty.
    ///   - abstract: The one-line summary.
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
    /// Host capabilities bound to this Ascendant, when the composition root
    /// offers them to the selected module. It is `nil` while adapters are
    /// built and present when a Positronic backend materializes.
    public let runtimeContext: PositronicContributionRuntimeContext?

    /// Creates the scoped configuration for one module invocation.
    public init(
        ascendant: NodeManifest.Ascendant,
        name: String,
        settings: [String: ManifestJSONValue],
        secrets: [String: ManifestJSONValue],
        runtimeContext: PositronicContributionRuntimeContext? = nil
    ) {
        self.ascendant = ascendant
        self.name = name
        self.settings = settings
        self.secrets = secrets
        self.runtimeContext = runtimeContext
    }

    /// Reads one string setting.
    ///
    /// - Parameter key: The module's own key, without the name-space prefix.
    /// - Returns: The value, or `nil` when the key is absent.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   key is present but is not a string.
    public func stringSetting(_ key: String) throws -> String? {
        try Self.string(key, in: settings, moduleName: name, isSecret: false)
    }

    /// Reads one string secret.
    ///
    /// - Parameter key: The module's own secret key, without the name-space
    ///   prefix.
    /// - Returns: The value, or `nil` when the key is absent.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   key is present but is not a string.
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
                "Positronic module '\(moduleName)' \(kind) '\(key)' must be a string."
            )
        }
        return text
    }
}
