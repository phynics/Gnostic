// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore
import GnosticKit
import GnosticLettaBackend

/// The composition source for clean Ascendant backend kinds and modules.
///
/// `gnostic serve` and `gnostic config` both build their
/// ``AscendantAdapterRegistry`` from this type, so a kind compiled into the CLI
/// is known to configuration commands and to a running Node, with the same
/// settings schema.
///
/// The clean host registers only backends that run inside the host process.
/// PositronicKit is deliberately absent: a Positronic Ascendant runs behind the
/// standalone ACP Runtime process boundary, so the host cannot materialize a
/// provider-specific agent here.
///
/// It also owns the registry of compiled-in ``GnosticModule`` descriptors. The
/// clean host ships no provider-specific module: legacy module composition lives
/// in the transitional target slated for deletion under #611.
public struct BackendComposition: Sendable {
    private var registry: AscendantAdapterRegistry
    private var modules: [String: GnosticModule]

    /// Creates a composition with no backend kinds.
    public init() {
        registry = AscendantAdapterRegistry()
        modules = [:]
    }

    /// The CLI's production composition.
    ///
    /// Carries optional Letta and ACP backends. Their factories construct a
    /// remote client only when a backend is materialized, so configuration
    /// listing stays free of credentials and network access.
    public static var `default`: BackendComposition {
        var composition = BackendComposition()
        composition.registerModule(KnownModuleCatalog.atlas)
        composition.registerModule(KnownModuleCatalog.rlm)
        composition.registerLettaBackend()
        composition.registerACPBackend()
        return composition
    }

    /// Every backend kind this composition can build.
    public var registeredKinds: Set<String> { registry.registeredKinds }

    /// Every compiled-in module, by static name.
    public var registeredModules: Set<String> { Set(modules.keys) }

    /// Every compiled-in module descriptor, sorted by static name.
    public var moduleDescriptors: [GnosticModule] {
        modules.values.sorted { $0.name < $1.name }
    }

    /// Looks up one compiled-in module by static name.
    public func moduleDescriptor(named name: String) -> GnosticModule? { modules[name] }

    /// Resolves the modules one Ascendant selects through `extensions`.
    ///
    /// This validates the selection shape but does not build a contribution or
    /// a credential-backed backend.
    public func selectedModuleNames(for ascendant: NodeManifest.Ascendant) throws -> [String] {
        try Self.selectedModuleNames(for: ascendant, backend: ascendant.backend)
    }

    /// The experiment subcommands the registered modules declare, sorted by name.
    public var registeredExperimentSubcommands: [GnosticModuleSubcommand] {
        modules.values
            .compactMap(\.experimentSubcommand)
            .sorted { $0.name < $1.name }
    }

    /// The configuration keys one registered kind understands.
    ///
    /// The advertised schema includes every registered module's name-spaced
    /// keys, so a generic configuration command can list and validate them
    /// without knowing the module.
    public func settingsSchema(for kind: String) -> AscendantBackendSettingsSchema? {
        registry.settingsSchema(for: kind)
    }

    /// Registers one compiled-in module.
    public mutating func registerModule(_ module: GnosticModule) {
        modules[module.name] = module
    }

    /// Registers an additional backend kind at the composition root.
    public mutating func registerBackend(
        kind: String,
        settings: AscendantBackendSettingsSchema = .unspecified,
        factory: @escaping AscendantAdapterRegistry.BackendFactory
    ) {
        registry.registerBackend(kind: kind, settings: settings, factory: factory)
    }

    /// Builds the Node adapters `serve` runs with.
    public func makeAdapters() -> NodeRuntimeAdapters {
        makeAdapters(for: [])
    }

    /// Builds the Node adapters `serve` runs with for a launch plan.
    ///
    /// Each Ascendant's selected modules install their terminal Turn observers
    /// for that Ascendant only. An Ascendant that selects no module installs no
    /// observer.
    public func makeAdapters(for ascendants: [NodeManifest.Ascendant]) -> NodeRuntimeAdapters {
        NodeRuntimeAdapters(
            ascendants: registry,
            terminalTurnObservers: terminalTurnObservers(for: ascendants)
        )
    }

    /// Installs the optional Letta backend over this composition.
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

    private func terminalTurnObservers(
        for ascendants: [NodeManifest.Ascendant]
    ) -> [any TerminalTurnObserving] {
        var installed: [any TerminalTurnObserving] = []
        for ascendant in ascendants {
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

    private static func selectedModuleNames(
        for ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration
    ) throws -> [String] {
        guard let value = backend.settings["extensions"] else { return [] }
        guard case let .array(items) = value else {
            throw AscendantBackendError.invalidConfiguration(
                "Ascendant '\(ascendant.name)' setting 'extensions' must be an array of module names."
            )
        }
        var names: [String] = []
        for item in items {
            guard case let .string(name) = item, !name.isEmpty else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' setting 'extensions' must contain only non-empty module names."
                )
            }
            guard !names.contains(name) else {
                throw AscendantBackendError.invalidConfiguration(
                    "Ascendant '\(ascendant.name)' selects module '\(name)' more than once."
                )
            }
            names.append(name)
        }
        return names
    }

    private static func scope(
        for module: GnosticModule,
        ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration
    ) -> GnosticModuleScope {
        GnosticModuleScope(
            ascendant: ascendant,
            name: module.name,
            settings: scoped(backend.settings, to: module.name),
            secrets: scoped(backend.secrets, to: module.name)
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
}

/// Filters a module's terminal Turn observer to the Ascendant that selected it.
struct AscendantScopedTerminalTurnObserver: TerminalTurnObserving {
    let ascendantID: UUID
    let wrapped: any TerminalTurnObserving

    func observe(_ record: TerminalTurnRecord) async throws {
        guard record.ascendantID == ascendantID else { return }
        try await wrapped.observe(record)
    }
}
