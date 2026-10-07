// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A registry of Ascendant backend factories keyed by the manifest's
/// `backend.kind` field.
///
/// ``init()`` pre-registers no kind. A composition root registers each kind it
/// ships, so the neutral kernel depends on no backend implementation.
public struct AscendantAdapterRegistry: Sendable {
    /// Builds one backend from its manifest slice and construction services.
    public typealias BackendFactory = @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration, _ services: AscendantBackendServices, _ timelines: [NodeManifest.Timeline]) async throws -> any AscendantBackend

    private var factories: [String: BackendFactory]
    private var schemas: [String: AscendantBackendSettingsSchema]

    /// Creates an empty registry.
    public init() {
        factories = [:]
        schemas = [:]
    }

    /// The manifest kind served by the bundled Positronic backend.
    ///
    /// The kernel advertises the constant so configuration and routing code can
    /// name the kind without depending on the implementation. The bundled
    /// implementation registers its factory from `GnosticPositronicBackend`.
    public static let positronicKind = "positronic"

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
    /// Builds one local Workspace from its manifest slice.
    public typealias ProductFactory = @MainActor @Sendable (_ configuration: NodeManifest.Workspace) throws -> any LocalWorkspace

    private var productFactories: [String: ProductFactory]

    /// Creates an empty registry.
    public init() {
        productFactories = [:]
    }

    /// Registers a Workspace factory for one manifest `kind`.
    ///
    /// - Parameters:
    ///   - kind: The manifest `workspaces[].kind` this factory serves.
    ///   - factory: Builds the Workspace for one configuration.
    public mutating func registerProduct(kind: String, factory: @escaping ProductFactory) {
        productFactories[kind] = factory
    }

    /// Every Workspace kind this registry can build.
    public var registeredKinds: Set<String> { Set(productFactories.keys) }

    @MainActor
    func makeWorkspace(for configuration: NodeManifest.Workspace) throws -> any LocalWorkspace {
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
/// deterministic, empty, and require no backend implementation, LLM, or broker
/// credentials.
public struct NodeRuntimeAdapters: Sendable {
    /// Builds the network Workspace invoker for a resolved catalog and
    /// communication manager.
    public typealias NetworkWorkspaceInvokerFactory = @MainActor @Sendable (_ catalog: NetworkCatalog, _ communication: CommunicationManager) -> any NetworkWorkspaceInvoking
    /// Builds the durable timeline store capability for one Ascendant.
    public typealias TimelineStoreFactory = @MainActor @Sendable (_ ascendantID: UUID, _ directory: URL) async throws -> any AscendantBackendOptionalCapability

    /// Ascendant backend factories.
    public var ascendants: AscendantAdapterRegistry
    /// Local Workspace factories.
    public var workspaces: WorkspaceAdapterRegistry
    /// Lifecycle fault-injection seams.
    public var lifecycle: NodeRuntimeLifecycleHooks
    /// Host-installed observers for backend-neutral terminal Turn records.
    public var terminalTurnObservers: [any TerminalTurnObserving]
    /// Builds the network Workspace invoker, when the host offers one.
    public var networkWorkspaceInvoker: NetworkWorkspaceInvokerFactory?
    /// Builds the durable timeline store capability, when the host offers one.
    public var timelineStore: TimelineStoreFactory?

    /// Creates the runtime adapter bundle.
    public init(
        ascendants: AscendantAdapterRegistry = .init(),
        workspaces: WorkspaceAdapterRegistry = .init(),
        lifecycle: NodeRuntimeLifecycleHooks = .init(),
        terminalTurnObservers: [any TerminalTurnObserving] = [],
        networkWorkspaceInvoker: NetworkWorkspaceInvokerFactory? = nil,
        timelineStore: TimelineStoreFactory? = nil
    ) {
        self.ascendants = ascendants
        self.workspaces = workspaces
        self.lifecycle = lifecycle
        self.terminalTurnObservers = terminalTurnObservers
        self.networkWorkspaceInvoker = networkWorkspaceInvoker
        self.timelineStore = timelineStore
    }

    /// The empty, implementation-free adapter bundle.
    public static var `default`: NodeRuntimeAdapters { .init() }
}
