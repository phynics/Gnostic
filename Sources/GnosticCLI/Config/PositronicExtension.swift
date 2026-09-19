// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// One compiled-in extension of the bundled Positronic backend.
///
/// Extensions are selected per Ascendant by name through the backend-owned
/// `extensions` setting. An extension's own keys are namespaced by its name in
/// the Positronic schema (`<name>.<key>`), so two extensions can declare the
/// same key without colliding. Secrets are namespaced the same way in
/// `backend.secrets`, which keeps them covered by the existing structural
/// redaction.
///
/// The registry lives in the CLI composition source; `GnosticCore` never
/// depends on an experiment target. An extension builds its contribution
/// through the generic ``PositronicContribution`` seam.
public struct PositronicExtension: Sendable {
    /// Builds one contribution from the extension's scoped configuration.
    ///
    /// - Parameter scope: The Ascendant and the extension's own settings.
    /// - Returns: The contribution the adapter installs.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   extension's settings are missing or malformed.
    public typealias Factory = @Sendable (PositronicExtensionScope) throws -> any PositronicContribution

    /// The static extension name used in the `extensions` setting.
    public let name: String
    /// The settings keys this extension understands, before name-spacing.
    public let settingKeys: [AscendantBackendSettingsSchema.Key]
    /// Builds the contribution for one Ascendant.
    public let factory: Factory

    /// Creates one compiled-in extension.
    ///
    /// - Parameters:
    ///   - name: The static selection name. It must not be empty.
    ///   - settingKeys: The extension's own keys, prefixed with `name` in the
    ///     Positronic schema.
    ///   - factory: Builds the contribution.
    public init(
        name: String,
        settingKeys: [AscendantBackendSettingsSchema.Key] = [],
        factory: @escaping Factory
    ) {
        // Scoping strips the `"\(name)."` prefix from an envelope, so a dot in
        // `name` would let one extension read another's settings. Extension
        // names are compiled in, so this is a composition-time programming
        // error rather than untrusted input.
        precondition(
            !name.isEmpty && !name.contains("."),
            "A Positronic extension name must be non-empty and must not contain '.'."
        )
        self.name = name
        self.settingKeys = settingKeys
        self.factory = factory
    }
}

/// The per-Ascendant configuration one selected extension reads.
///
/// ``settings`` and ``secrets`` are keyed without the extension's name-space
/// prefix, so an extension only ever sees its own values.
public struct PositronicExtensionScope: Sendable {
    /// The Ascendant selecting the extension.
    public let ascendant: NodeManifest.Ascendant
    /// The extension's static name.
    public let name: String
    /// The extension's settings, keyed without the name-space prefix.
    public let settings: [String: ManifestJSONValue]
    /// The extension's secrets, keyed without the name-space prefix.
    public let secrets: [String: ManifestJSONValue]

    /// Creates the scoped configuration for one extension invocation.
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
    ///
    /// - Parameter key: The extension's own key, without the name-space prefix.
    /// - Returns: The value, or `nil` when the key is absent.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   key is present but is not a string.
    public func stringSetting(_ key: String) throws -> String? {
        try Self.string(key, in: settings, extensionName: name, isSecret: false)
    }

    /// Reads one string secret.
    ///
    /// - Parameter key: The extension's own secret key, without the
    ///   name-space prefix.
    /// - Returns: The value, or `nil` when the key is absent.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   key is present but is not a string.
    public func stringSecret(_ key: String) throws -> String? {
        try Self.string(key, in: secrets, extensionName: name, isSecret: true)
    }

    private static func string(
        _ key: String,
        in values: [String: ManifestJSONValue],
        extensionName: String,
        isSecret: Bool
    ) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case let .string(text) = value else {
            let kind = isSecret ? "secret" : "setting"
            throw AscendantBackendError.invalidConfiguration(
                "Positronic extension '\(extensionName)' \(kind) '\(key)' must be a string."
            )
        }
        return text
    }
}
