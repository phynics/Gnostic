// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
@_spi(RuntimeHost) import GnosticCore

/// The composition source for ACP Runtime adapters.
///
/// `gnostic serve` and `gnostic config` both build their
/// ``AscendantAdapterRegistry`` from this type, so a kind compiled into the CLI
/// is known to configuration commands and to a running Node, with the same
/// settings schema.
///
/// The production host registers the ACP process adapter. PositronicKit is
/// deliberately absent: the reference Runtime runs behind the standalone ACP
/// process boundary, so the host cannot materialize its model loop here.
///
public struct BackendComposition: Sendable {
    private var registry: AscendantAdapterRegistry

    /// Creates a composition with no backend kinds.
    public init() {
        registry = AscendantAdapterRegistry()
    }

    /// The CLI's production composition.
    ///
    /// Registers the ACP process adapter for configured Runtime instances.
    public static var `default`: BackendComposition {
        var composition = BackendComposition()
        composition.registerACPBackend()
        return composition
    }

    /// Every backend kind this composition can build.
    public var registeredKinds: Set<String> { registry.registeredKinds }

    /// The configuration keys one registered kind understands.
    ///
    /// The advertised schema lets configuration commands list and validate
    /// the keys the registered Runtime kind understands.
    public func settingsSchema(for kind: String) -> AscendantBackendSettingsSchema? {
        registry.settingsSchema(for: kind)
    }

    /// Registers a backend kind for host composition and test fixtures.
    ///
    /// This SPI is implementation plumbing, not a supported in-process Runtime
    /// extension point. Production Runtime integrations use ACP over stdio.
    @_spi(RuntimeHost)
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

    /// Builds the Node adapters `serve` runs with. The launch plan is accepted
    /// for source compatibility; ACP adapter composition is manifest-neutral.
    public func makeAdapters(for _: [NodeManifest.Ascendant]) -> NodeRuntimeAdapters {
        return NodeRuntimeAdapters(ascendants: registry)
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
}
