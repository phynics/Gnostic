// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// A registry of Ascendant backend factories keyed by the manifest's
/// `backend.kind` field.
///
/// ``init()`` pre-registers one kind, `"positronic"`, bound to an
/// unconfigured language model. A composition root that can supply a
/// configured model re-registers the same kind through
/// ``registerBackend(kind:factory:)``.
public struct AscendantAdapterRegistry: Sendable {
    public typealias BackendFactory = @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration, _ services: AscendantBackendServices, _ timelines: [NodeManifest.Timeline]) async throws -> any AscendantBackend

    private var factories: [String: BackendFactory]
    private var schemas: [String: AscendantBackendSettingsSchema]

    public init() {
        factories = [Self.positronicKind: { ascendant, backend, services, timelines in
            try await PositronicAscendantAdapter(ascendant: ascendant, backend: backend, services: services, timelines: timelines, languageModel: UnconfiguredLLMService())
        }]
        schemas = [Self.positronicKind: PositronicAscendantAdapter.settingsSchema]
    }

    /// Every backend kind this registry can build.
    public var registeredKinds: Set<String> { Set(factories.keys) }

    /// The configuration keys one registered kind understands.
    ///
    /// - Parameter kind: The manifest `backend.kind` to look up.
    /// - Returns: The kind's schema, ``AscendantBackendSettingsSchema/unspecified``
    ///   when it was registered without one, or `nil` when the kind is not
    ///   registered at all.
    public func settingsSchema(for kind: String) -> AscendantBackendSettingsSchema? {
        guard factories[kind] != nil else { return nil }
        return schemas[kind] ?? .unspecified
    }

    /// Registers a backend factory for one manifest `kind`.
    ///
    /// This is the only supported selection point for a backend kind.
    /// Registering a kind that is already present replaces it.
    ///
    /// - Parameters:
    ///   - kind: The manifest `backend.kind` this factory serves.
    ///   - settings: The configuration keys this kind understands, so a
    ///     composition root can list and check them without knowing the kind.
    ///   - factory: Builds the backend for one Ascendant.
    public mutating func registerBackend(
        kind: String,
        settings: AscendantBackendSettingsSchema = .unspecified,
        factory: @escaping BackendFactory
    ) {
        factories[kind] = factory
        schemas[kind] = settings
    }

    /// Registers the bundled Positronic backend with a caller-supplied
    /// language model.
    ///
    /// The kind is fixed to `"positronic"` because this seam always builds a
    /// ``PositronicAscendantAdapter``. Use ``registerBackend(kind:factory:)``
    /// for any other backend.
    ///
    /// - Parameter factory: Supplies the language model for one Ascendant.
    public mutating func registerPositronicBackend(
        languageModel factory: @escaping @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration) -> any LLMStreamClient
    ) {
        factories[Self.positronicKind] = { ascendant, backend, services, timelines in
            try await PositronicAscendantAdapter(ascendant: ascendant, backend: backend, services: services, timelines: timelines, languageModel: factory(ascendant, backend))
        }
        schemas[Self.positronicKind] = PositronicAscendantAdapter.settingsSchema
    }

    /// The kind served by the bundled Positronic backend.
    public static let positronicKind = "positronic"

    @MainActor
    func makeBackend(for ascendant: NodeManifest.Ascendant, backend: AscendantBackendConfiguration, services: AscendantBackendServices, timelines: [NodeManifest.Timeline]) async throws -> any AscendantBackend {
        try AscendantBackendConfigurationValidator.validate(backend)
        guard let factory = factories[backend.kind] else { throw NodeRuntimeError.unsupportedAscendantKind(backend.kind) }
        return try await factory(ascendant, backend, services, timelines)
    }

    func validate(kinds: some Sequence<String>) throws {
        for kind in kinds where factories[kind] == nil {
            throw NodeRuntimeError.unsupportedAscendantKind(kind)
        }
    }
}

/// A registry of local Workspace adapters keyed by the manifest's `kind` field.
public struct WorkspaceAdapterRegistry: Sendable {
    /// The adapter owns its final reference and tool projection.
    public typealias ProductFactory = @Sendable (_ configuration: NodeManifest.Workspace) throws -> any WorkspaceProvider

    private var productFactories: [String: ProductFactory]

    public init() {
        productFactories = ["echo": { configuration in
            guard let uri = WorkspaceURI(parsing: configuration.uri) else {
                throw NodeRuntimeError.invalidWorkspaceURI(configuration.id)
            }
            let reference = WorkspaceReference(
                id: configuration.id,
                uri: uri,
                location: .runtime,
                tools: EchoWorkspace.toolDefinitions
            )
            return EchoWorkspace(reference: reference)
        }]
    }

    public mutating func registerProduct(kind: String, factory: @escaping ProductFactory) {
        productFactories[kind] = factory
    }

    /// Every Workspace kind this registry can build.
    public var registeredKinds: Set<String> { Set(productFactories.keys) }

    @MainActor
    func makeWorkspace(for configuration: NodeManifest.Workspace) throws -> any WorkspaceProvider {
        guard let factory = productFactories[configuration.kind] else {
            throw NodeRuntimeError.unsupportedWorkspaceKind(configuration.kind)
        }
        return try factory(configuration)
    }

    func validate(kinds: some Sequence<String>) throws {
        for kind in kinds where productFactories[kind] == nil {
            throw NodeRuntimeError.unsupportedWorkspaceKind(kind)
        }
    }
}

/// Testable lifecycle seams used to prove startup rollback without depending
/// on a live broker failure. Production callers use the no-op default.
public struct NodeRuntimeLifecycleHooks: Sendable {
    public var afterConnection: @Sendable () throws -> Void
    public var afterRegistration: @Sendable () throws -> Void
    public var beforeAdvertisement: @Sendable () throws -> Void
    public var beforeDiscoverResponder: @Sendable () async throws -> Void
    public var afterDiscoverResponder: @Sendable () async throws -> Void
    public var afterAdvertisement: @Sendable () async throws -> Void

    public init(
        afterConnection: @escaping @Sendable () throws -> Void = {},
        afterRegistration: @escaping @Sendable () throws -> Void = {},
        beforeAdvertisement: @escaping @Sendable () throws -> Void = {},
        beforeDiscoverResponder: @escaping @Sendable () async throws -> Void = {},
        afterDiscoverResponder: @escaping @Sendable () async throws -> Void = {},
        afterAdvertisement: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.afterConnection = afterConnection
        self.afterRegistration = afterRegistration
        self.beforeAdvertisement = beforeAdvertisement
        self.beforeDiscoverResponder = beforeDiscoverResponder
        self.afterDiscoverResponder = afterDiscoverResponder
        self.afterAdvertisement = afterAdvertisement
    }
}

/// Dependency-injection boundary for NodeRuntime. The default registries are
/// deterministic and require no LLM or broker credentials.
public struct NodeRuntimeAdapters: Sendable {
    public var ascendants: AscendantAdapterRegistry
    public var workspaces: WorkspaceAdapterRegistry
    public var lifecycle: NodeRuntimeLifecycleHooks
    /// Host-installed observers for backend-neutral terminal Turn records.
    public var terminalTurnObservers: [any TerminalTurnObserving]

    public init(
        ascendants: AscendantAdapterRegistry = .init(),
        workspaces: WorkspaceAdapterRegistry = .init(),
        lifecycle: NodeRuntimeLifecycleHooks = .init(),
        terminalTurnObservers: [any TerminalTurnObserving] = []
    ) {
        self.ascendants = ascendants
        self.workspaces = workspaces
        self.lifecycle = lifecycle
        self.terminalTurnObservers = terminalTurnObservers
    }

    public static var `default`: NodeRuntimeAdapters { .init() }
}

/// A local echo Workspace implementation. All configured echo Workspaces use
/// the same multiplexed provider route while retaining their own stable IDs.
public struct EchoWorkspace: WorkspaceToolProvider, WorkspaceFileProvider, Sendable {
    public static let toolID = "workspace_echo"
    public static let toolDefinitions: [ToolReference] = [.custom(.init(
        id: toolID,
        name: "Workspace echo",
        description: "Echoes a value from the workspace.",
        parametersSchema: [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["value": AnyCodable(["type": AnyCodable("string")])]),
            "required": AnyCodable(["value"]),
            "additionalProperties": AnyCodable(false)
        ]
    ))]

    public let reference: WorkspaceReference
    public var id: UUID { reference.id }

    public init(reference: WorkspaceReference) { self.reference = reference }

    /// Echo owns its tool projection rather than trusting the reference it
    /// was constructed with.
    public func listTools() async throws -> [ToolReference] { Self.toolDefinitions }

    public func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard id == Self.toolID else { throw WorkspaceError.toolExecutionNotSupported }
        return .success(parameters["value"]?.value as? String ?? "")
    }

    public func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    public func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public func listFiles(path _: String) async throws -> [String] { [] }
    public func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public var isHealthy: Bool { true }
}
