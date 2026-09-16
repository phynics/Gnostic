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
/// Listing kinds and schemas never constructs a backend, a language model, or a
/// credential-backed client. The bundled Positronic factory builds its model
/// lazily, inside the factory, only when `serve` materializes an Ascendant.
public struct BackendComposition: Sendable {
    private var registry: AscendantAdapterRegistry

    /// Creates a composition with only the registrations Core provides.
    public init() {
        registry = AscendantAdapterRegistry()
    }

    /// The CLI's production composition.
    ///
    /// Carries the bundled Positronic backend. Its factory constructs the
    /// configured language model only when a backend is materialized, so
    /// configuration listing stays free of credentials and network access.
    public static let `default`: BackendComposition = {
        var composition = BackendComposition()
        composition.registry.registerPositronicBackend { _, backend in
            let configuration = PositronicBackendConfiguration(backend: backend)
            return configuration.provider != nil
                ? ConfiguredLLMService.make(from: configuration)
                : UnconfiguredLLMService()
        }
        return composition
    }()

    /// Every backend kind this composition can build.
    public var registeredKinds: Set<String> { registry.registeredKinds }

    /// The configuration keys one registered kind understands.
    ///
    /// - Parameter kind: The manifest `backend.kind` to look up.
    /// - Returns: The kind's schema, or `nil` when the kind is not registered.
    public func settingsSchema(for kind: String) -> AscendantBackendSettingsSchema? {
        registry.settingsSchema(for: kind)
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
    /// Workspace and lifecycle seams stay at their defaults; only the Ascendant
    /// registry comes from this composition.
    ///
    /// - Returns: Adapters carrying this composition's backend registry.
    public func makeAdapters() -> NodeRuntimeAdapters {
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants = registry
        return adapters
    }
}
