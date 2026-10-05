// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore
import GnosticLettaBackend
import PositronicKit

/// The single CLI composition source for Ascendant backend kinds and modules.
///
/// `gnostic serve` and `gnostic config` both build their
/// ``AscendantAdapterRegistry`` from this type, so a kind compiled into the CLI
/// is known to configuration commands and to a running Node, with the same
/// settings schema.
///
/// It also owns the registry of compiled-in ``GnosticModule`` values. An
/// Ascendant selects modules by name through the backend-owned `extensions`
/// setting, so two Positronic Ascendants on one Node can run different setups
/// without a distinct backend kind. One module declaration covers its
/// contribution, its terminal Turn observers, its settings, and its optional
/// experiment subcommand.
///
/// Listing kinds and schemas never constructs a backend, a language model, or a
/// credential-backed client. The bundled Positronic factory builds its model
/// lazily, inside the factory, only when `serve` materializes an Ascendant.
public struct BackendComposition: Sendable {
    private var registry: AscendantAdapterRegistry
    private var modules: [String: GnosticModule]

    /// Creates a composition with only the registrations Core provides.
    public init() {
        registry = AscendantAdapterRegistry()
        modules = [:]
    }

    /// The CLI's production composition.
    ///
    /// Carries the bundled Positronic backend and optional Letta and ACP backends.
    /// Their factories construct a model or a remote client only when a
    /// backend is materialized, so configuration listing stays free of
    /// credentials and network access.
    public static var `default`: BackendComposition {
        var composition = BackendComposition()
        composition.registerModule(AtlasModule.value)
        composition.registerModule(RLMModule.value)
        composition.registerLettaBackend()
        composition.registerACPBackend()
        return composition
    }

    /// Every backend kind this composition can build.
    public var registeredKinds: Set<String> { registry.registeredKinds }

    /// Every compiled-in module, by static name.
    public var registeredModules: Set<String> { Set(modules.keys) }

    /// Every compiled-in module that installs a Positronic contribution.
    ///
    /// This is ``registeredModules`` filtered to modules that build a
    /// contribution, so configuration listing can advertise only the names that
    /// change the Positronic adapter.
    public var registeredPositronicExtensions: Set<String> {
        Set(modules.values.filter { $0.contribution != nil }.map(\.name))
    }

    /// The experiment subcommands the registered modules declare, sorted by name.
    ///
    /// A module's optional experiment subcommand is live only when its
    /// descriptor declares it, so an app can discover module-contributed
    /// subcommands instead of keeping its own module registry. The app owns
    /// argument parsing and rendering; `GnosticHost` never depends on
    /// `ArgumentParser`.
    public var registeredExperimentSubcommands: [GnosticModuleSubcommand] {
        modules.values
            .compactMap(\.experimentSubcommand)
            .sorted { $0.name < $1.name }
    }

    /// The configuration keys one registered kind understands.
    ///
    /// For the bundled Positronic kind the advertised schema also includes
    /// every registered module's name-spaced keys, so a generic configuration
    /// command can list and validate them without knowing the module.
    ///
    /// - Parameter kind: The manifest `backend.kind` to look up.
    /// - Returns: The kind's schema, or `nil` when the kind is not registered.
    public func settingsSchema(for kind: String) -> AscendantBackendSettingsSchema? {
        guard let base = registry.settingsSchema(for: kind) else { return nil }
        guard kind == AscendantAdapterRegistry.positronicKind else { return base }
        return AscendantBackendSettingsSchema(keys: base.keys + Self.moduleKeys(modules))
    }

    /// Registers one compiled-in module.
    ///
    /// Registering a name that is already present replaces it.
    ///
    /// - Parameter module: The module to register.
    public mutating func registerModule(_ module: GnosticModule) {
        modules[module.name] = module
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
    /// module registry, so a module registered after construction is honored.
    /// Workspace and lifecycle seams stay at their defaults.
    ///
    /// - Returns: Adapters carrying this composition's backend registry and no
    ///   module-scoped terminal Turn observers.
    public func makeAdapters() -> NodeRuntimeAdapters {
        makeAdapters(for: [])
    }

    /// Builds the Node adapters `serve` runs with for a launch plan.
    ///
    /// Each Ascendant's selected modules install their terminal Turn observers
    /// for that Ascendant only. An Ascendant that selects no module installs no
    /// observer, so an existing manifest behaves exactly as before.
    ///
    /// - Parameter ascendants: The launch plan's Ascendants.
    /// - Returns: Adapters carrying this composition's backend registry and the
    ///   selected module observers.
    public func makeAdapters(for ascendants: [NodeManifest.Ascendant]) -> NodeRuntimeAdapters {
        var copy = self
        copy.installPositronicBackend()
        return NodeRuntimeAdapters(
            ascendants: copy.registry,
            terminalTurnObservers: copy.terminalTurnObservers(for: ascendants)
        )
    }

    /// Installs the optional Letta backend over this composition.
    ///
    /// The kind is registered with its advertised settings schema, so
    /// `gnostic config backend keys` lists the Letta keys without constructing
    /// a backend or contacting a Letta server.
    private mutating func registerLettaBackend() {
        registry.registerBackend(
            kind: LettaAscendantBackend.kind,
            settings: LettaAscendantBackend.settingsSchema
        ) { ascendant, backend, services, timelines in
            try LettaAscendantBackend(
                ascendant: ascendant,
                configuration: backend,
                services: services,
                timelines: timelines
            )
        }
    }

    /// Installs the configuration-only ACP backend and its CLI schema.
    private mutating func registerACPBackend() {
        registry.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backend, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backend,
                services: services,
                timelines: timelines
            )
        }
    }

    /// Installs the bundled Positronic factory over this composition's modules.
    private mutating func installPositronicBackend() {
        let modules = modules
        registry.registerBackend(
            kind: AscendantAdapterRegistry.positronicKind,
            settings: PositronicAscendantAdapter.settingsSchema
        ) { ascendant, backend, services, timelines in
            let configuration = PositronicBackendConfiguration(backend: backend)
            let selectedNames = try Self.selectedModuleNames(for: ascendant, backend: backend)
            let needsDedicatedModel = selectedNames.contains { modules[$0]?.requiresModelService == true }
            let modelClient: any LLMStreamClient = configuration.provider != nil
                ? ConfiguredLLMService.make(from: configuration)
                : UnconfiguredLLMService()
            let dedicatedModel: (any PositronicContributionModelService)? = needsDedicatedModel && configuration.provider != nil
                ? PositronicContributionModelAdapter(client: modelClient)
                : nil
            let allowedWorkspaceIDs = Set(
                timelines
                    .filter { $0.operatingAscendantID == ascendant.id }
                    .flatMap(\.attachments)
                    .filter { $0.scope == .local }
                    .map(\.workspaceID)
            )
            let runtimeContext: PositronicContributionRuntimeContext? = selectedNames.isEmpty
                ? nil
                : PositronicContributionRuntimeContext(
                    services: services,
                    modelService: dedicatedModel,
                    allowedWorkspaceIDs: allowedWorkspaceIDs
                )
            let contributions = try Self.contributions(
                for: ascendant,
                backend: backend,
                modules: modules,
                runtimeContext: runtimeContext
            )
            return try await PositronicAscendantAdapter(
                ascendant: ascendant,
                backend: backend,
                services: services,
                timelines: timelines,
                languageModel: modelClient,
                contributions: contributions
            )
        }
    }

    /// Builds the terminal Turn observers the selected modules install.
    ///
    /// A malformed selection is skipped here and fails later, when the
    /// Positronic backend factory materializes the Ascendant, so the error
    /// still surfaces before advertisement.
    private func terminalTurnObservers(
        for ascendants: [NodeManifest.Ascendant]
    ) -> [any TerminalTurnObserving] {
        var installed: [any TerminalTurnObserving] = []
        for ascendant in ascendants {
            guard ascendant.backend.kind == AscendantAdapterRegistry.positronicKind else { continue }
            guard let names = try? Self.selectedModuleNames(for: ascendant, backend: ascendant.backend) else { continue }
            for name in names {
                guard let module = modules[name] else { continue }
                let scope = Self.scope(for: module, ascendant: ascendant, backend: ascendant.backend)
                for makeObserver in module.terminalTurnObservers {
                    installed.append(
                        AscendantScopedTerminalTurnObserver(
                            ascendantID: ascendant.id,
                            wrapped: makeObserver(scope)
                        )
                    )
                }
            }
        }
        return installed
    }

    /// Resolves the contributions one Ascendant selected.
    ///
    /// A selected module without a contribution factory contributes nothing.
    ///
    /// - Parameters:
    ///   - ascendant: The Ascendant whose envelope is being materialized.
    ///   - backend: The Ascendant's backend envelope.
    ///   - modules: The registry of compiled-in modules.
    ///   - runtimeContext: Host capabilities bound to this Ascendant.
    /// - Returns: The selected contributions, in selection order.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   selection is malformed or names an unregistered module.
    static func contributions(
        for ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration,
        modules: [String: GnosticModule],
        runtimeContext: PositronicContributionRuntimeContext? = nil
    ) throws -> [any PositronicContribution] {
        let names = try selectedModuleNames(for: ascendant, backend: backend)
        return try names.compactMap { name in
            guard let module = modules[name] else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' selects unknown Positronic module '\(name)'. Known modules: \(knownModuleList(modules))."
                )
            }
            guard let factory = module.contribution else { return nil }
            return try factory(
                scope(
                    for: module,
                    ascendant: ascendant,
                    backend: backend,
                    runtimeContext: runtimeContext
                )
            )
        }
    }

    /// Reads and validates the `extensions` selection from one envelope.
    private static func selectedModuleNames(
        for ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration
    ) throws -> [String] {
        guard let value = backend.settings["extensions"] else { return [] }
        guard case let .array(items) = value else {
            throw AscendantBackendError.invalidConfiguration(
                "Ascendant '\(ascendant.name)' Positronic setting 'extensions' must be an array of module names."
            )
        }
        var names: [String] = []
        for item in items {
            guard case let .string(name) = item, !name.isEmpty else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' Positronic setting 'extensions' must contain only non-empty module names."
                )
            }
            guard !names.contains(name) else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' selects Positronic module '\(name)' more than once."
                )
            }
            names.append(name)
        }
        return names
    }

    /// Projects one module's name-spaced settings into its scope.
    private static func scope(
        for module: GnosticModule,
        ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration,
        runtimeContext: PositronicContributionRuntimeContext? = nil
    ) -> GnosticModuleScope {
        GnosticModuleScope(
            ascendant: ascendant,
            name: module.name,
            settings: scoped(backend.settings, to: module.name),
            secrets: scoped(backend.secrets, to: module.name),
            runtimeContext: runtimeContext
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

    private static func moduleKeys(
        _ modules: [String: GnosticModule]
    ) -> [AscendantBackendSettingsSchema.Key] {
        modules.values
            .sorted { $0.name < $1.name }
            .flatMap { module in
                module.settingKeys.map { key in
                    AscendantBackendSettingsSchema.Key(
                        name: "\(module.name).\(key.name)",
                        summary: "\(module.name) module: \(key.summary)",
                        isSecret: key.isSecret
                    )
                }
            }
    }

    private static func knownModuleList(_ modules: [String: GnosticModule]) -> String {
        let names = modules.keys.sorted()
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

/// Filters a module's terminal Turn observer to the Ascendant that selected it.
///
/// A module factory may share one observer across Ascendants, or the runtime
/// may route a record that belongs to another Ascendant. The wrapper keeps the
/// module's effect scoped to its own Ascendant.
struct AscendantScopedTerminalTurnObserver: TerminalTurnObserving {
    let ascendantID: UUID
    let wrapped: any TerminalTurnObserving

    func observe(_ record: TerminalTurnRecord) async throws {
        guard record.ascendantID == ascendantID else { return }
        try await wrapped.observe(record)
    }
}
