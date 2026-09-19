// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore
import PositronicKit

/// The single CLI composition source for Ascendant backend kinds.
///
/// `gnostic serve` and `gnostic config` both build their
/// ``AscendantAdapterRegistry`` from this type, so a kind compiled into the CLI
/// is known to configuration commands and to a running Node, with the same
/// settings schema.
///
/// It also owns the registry of compiled-in Positronic extensions. An
/// Ascendant selects extensions by name through the backend-owned `extensions`
/// setting, so two Positronic Ascendants on one Node can run different setups
/// without a distinct backend kind.
///
/// Listing kinds and schemas never constructs a backend, a language model, or a
/// credential-backed client. The bundled Positronic factory builds its model
/// lazily, inside the factory, only when `serve` materializes an Ascendant.
public struct BackendComposition: Sendable {
    private var registry: AscendantAdapterRegistry
    private var positronicExtensions: [String: PositronicExtension]

    /// Creates a composition with only the registrations Core provides.
    public init() {
        registry = AscendantAdapterRegistry()
        positronicExtensions = [:]
    }

    /// The CLI's production composition.
    ///
    /// Carries the bundled Positronic backend. Its factory constructs the
    /// configured language model only when a backend is materialized, so
    /// configuration listing stays free of credentials and network access.
    public static let `default` = BackendComposition()

    /// Every backend kind this composition can build.
    public var registeredKinds: Set<String> { registry.registeredKinds }

    /// Every compiled-in Positronic extension, by static name.
    public var registeredPositronicExtensions: Set<String> { Set(positronicExtensions.keys) }

    /// The configuration keys one registered kind understands.
    ///
    /// For the bundled Positronic kind the advertised schema also includes
    /// every registered extension's name-spaced keys, so a generic
    /// configuration command can list and validate them without knowing the
    /// extension.
    ///
    /// - Parameter kind: The manifest `backend.kind` to look up.
    /// - Returns: The kind's schema, or `nil` when the kind is not registered.
    public func settingsSchema(for kind: String) -> AscendantBackendSettingsSchema? {
        guard let base = registry.settingsSchema(for: kind) else { return nil }
        guard kind == AscendantAdapterRegistry.positronicKind else { return base }
        return AscendantBackendSettingsSchema(keys: base.keys + Self.extensionKeys(positronicExtensions))
    }

    /// Registers one compiled-in Positronic extension.
    ///
    /// Registering a name that is already present replaces it.
    ///
    /// - Parameter extensionValue: The extension to register.
    public mutating func registerPositronicExtension(_ extensionValue: PositronicExtension) {
        positronicExtensions[extensionValue.name] = extensionValue
    }

    /// Registers an additional backend kind at the composition root.
    ///
    /// This is the only seam a compiled-in kind uses; `serve` and `config`
    /// discover it through ``registeredKinds`` and ``settingsSchema(for:)``.
    ///
    /// - Parameters:
    ///   - kind: The manifest `backend.kind` this factory serves.
    ///   - settings: The configuration keys this kind understands.
    ///   - factory: Builds the backend for one Ascendant.
    public mutating func registerBackend(
        kind: String,
        settings: AscendantBackendSettingsSchema = .unspecified,
        factory: @escaping AscendantAdapterRegistry.BackendFactory
    ) {
        registry.registerBackend(kind: kind, settings: settings, factory: factory)
    }

    /// Builds the Node adapters `serve` runs with.
    ///
    /// The Positronic factory is (re)installed with this composition's current
    /// extension registry, so an extension registered after construction is
    /// honored. Workspace and lifecycle seams stay at their defaults.
    ///
    /// - Returns: Adapters carrying this composition's backend registry.
    public func makeAdapters() -> NodeRuntimeAdapters {
        var copy = self
        copy.installPositronicBackend()
        return NodeRuntimeAdapters(ascendants: copy.registry)
    }

    /// Installs the bundled Positronic factory over this composition's
    /// extensions.
    private mutating func installPositronicBackend() {
        let extensions = positronicExtensions
        registry.registerBackend(
            kind: AscendantAdapterRegistry.positronicKind,
            settings: PositronicAscendantAdapter.settingsSchema
        ) { ascendant, backend, services, timelines in
            let contributions = try Self.contributions(
                for: ascendant,
                backend: backend,
                extensions: extensions
            )
            let configuration = PositronicBackendConfiguration(backend: backend)
            let languageModel: any LLMStreamClient = configuration.provider != nil
                ? ConfiguredLLMService.make(from: configuration)
                : UnconfiguredLLMService()
            return try await PositronicAscendantAdapter(
                ascendant: ascendant,
                backend: backend,
                services: services,
                timelines: timelines,
                languageModel: languageModel,
                contributions: contributions
            )
        }
    }

    /// Resolves the contributions one Ascendant selected.
    ///
    /// - Parameters:
    ///   - ascendant: The Ascendant whose envelope is being materialized.
    ///   - backend: The Ascendant's backend envelope.
    ///   - extensions: The registry of compiled-in extensions.
    /// - Returns: The selected contributions, in selection order.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   selection is malformed or names an unregistered extension.
    static func contributions(
        for ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration,
        extensions: [String: PositronicExtension]
    ) throws -> [any PositronicContribution] {
        let names = try selectedExtensionNames(for: ascendant, backend: backend)
        return try names.map { name in
            guard let extensionValue = extensions[name] else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' selects unknown Positronic extension '\(name)'. Known extensions: \(knownExtensionList(extensions))."
                )
            }
            return try extensionValue.factory(
                scope(for: extensionValue, ascendant: ascendant, backend: backend)
            )
        }
    }

    /// Reads and validates the `extensions` selection from one envelope.
    private static func selectedExtensionNames(
        for ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration
    ) throws -> [String] {
        guard let value = backend.settings["extensions"] else { return [] }
        guard case let .array(items) = value else {
            throw AscendantBackendError.invalidConfiguration(
                "Ascendant '\(ascendant.name)' Positronic setting 'extensions' must be an array of extension names."
            )
        }
        var names: [String] = []
        for item in items {
            guard case let .string(name) = item, !name.isEmpty else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' Positronic setting 'extensions' must contain only non-empty extension names."
                )
            }
            guard !names.contains(name) else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' selects Positronic extension '\(name)' more than once."
                )
            }
            names.append(name)
        }
        return names
    }

    /// Projects one extension's name-spaced settings into its scope.
    private static func scope(
        for extensionValue: PositronicExtension,
        ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration
    ) -> PositronicExtensionScope {
        PositronicExtensionScope(
            ascendant: ascendant,
            name: extensionValue.name,
            settings: scoped(backend.settings, to: extensionValue.name),
            secrets: scoped(backend.secrets, to: extensionValue.name)
        )
    }

    private static func scoped(
        _ values: [String: ManifestJSONValue],
        to name: String
    ) -> [String: ManifestJSONValue] {
        let prefix = "\(name)."
        return values.reduce(into: [:]) { result, entry in
            guard entry.key.hasPrefix(prefix) else { return }
            result[String(entry.key.dropFirst(prefix.count))] = entry.value
        }
    }

    private static func extensionKeys(
        _ extensions: [String: PositronicExtension]
    ) -> [AscendantBackendSettingsSchema.Key] {
        extensions.values
            .sorted { $0.name < $1.name }
            .flatMap { extensionValue in
                extensionValue.settingKeys.map { key in
                    AscendantBackendSettingsSchema.Key(
                        name: "\(extensionValue.name).\(key.name)",
                        summary: "\(extensionValue.name) extension: \(key.summary)",
                        isSecret: key.isSecret
                    )
                }
            }
    }

    private static func knownExtensionList(_ extensions: [String: PositronicExtension]) -> String {
        let names = extensions.keys.sorted()
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}
