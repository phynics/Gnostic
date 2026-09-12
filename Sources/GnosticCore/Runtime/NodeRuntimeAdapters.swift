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

    public init() {
        factories = [Self.positronicKind: { ascendant, backend, services, timelines in
            try await PositronicAscendantAdapter(ascendant: ascendant, backend: backend, services: services, timelines: timelines, languageModel: UnconfiguredLLMService())
        }]
    }

    /// Registers a backend factory for one manifest `kind`.
    ///
    /// This is the only supported selection point for a backend kind.
    /// Registering a kind that is already present replaces it.
    ///
    /// - Parameters:
    ///   - kind: The manifest `backend.kind` this factory serves.
    ///   - factory: Builds the backend for one Ascendant.
    public mutating func registerBackend(kind: String, factory: @escaping BackendFactory) {
        factories[kind] = factory
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
    }

    /// The kind served by the bundled Positronic backend.
    public static let positronicKind = "positronic"

    /// Registers a Positronic language model under an arbitrary kind.
    ///
    /// This seam accepted any `kind` but only ever built a
    /// ``PositronicAscendantAdapter``, so a foreign kind produced a backend
    /// that failed semantic validation at startup with a message that did not
    /// name the mistake.
    @available(*, deprecated, message: "Use registerPositronicBackend(languageModel:) for the bundled backend, or registerBackend(kind:factory:) for any other kind.")
    public mutating func register(kind: String, languageModel factory: @escaping @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration) -> any LLMStreamClient) {
        guard kind == Self.positronicKind else {
            factories[kind] = { _, _, _, _ in
                throw AscendantBackendError.invalidConfiguration(
                    "Backend kind '\(kind)' cannot be registered through the Positronic language-model seam, which only builds a Positronic backend. Use registerBackend(kind:factory:) instead."
                )
            }
            return
        }
        registerPositronicBackend(languageModel: factory)
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
    public typealias Factory = @Sendable (_ configuration: NodeManifest.Workspace, _ reference: WorkspaceReference) throws -> any WorkspaceProvider
    /// Preferred factory seam. The adapter owns its final reference and tool
    /// projection instead of receiving a runtime-owned provisional reference.
    public typealias ProductFactory = @Sendable (_ configuration: NodeManifest.Workspace) throws -> any WorkspaceProvider

    private var factories: [String: Factory]
    private var productFactories: [String: ProductFactory]

    public init() {
        factories = [:]
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

    /// Registers a legacy factory that accepts a compatibility reference.
    /// New adapters should use `registerProduct(kind:factory:)` so that the
    /// adapter, rather than NodeRuntime, owns its identity and tools.
    @available(*, deprecated, message: "Use registerProduct(kind:factory:) so the adapter owns its final WorkspaceReference.")
    public mutating func register(kind: String, factory: @escaping Factory) {
        factories[kind] = factory
        productFactories.removeValue(forKey: kind)
    }

    public mutating func registerProduct(kind: String, factory: @escaping ProductFactory) {
        productFactories[kind] = factory
        factories.removeValue(forKey: kind)
    }

    @MainActor
    func makeWorkspace(for configuration: NodeManifest.Workspace) throws -> any WorkspaceProvider {
        if let factory = productFactories[configuration.kind] {
            return try factory(configuration)
        }
        guard let factory = factories[configuration.kind] else {
            throw NodeRuntimeError.unsupportedWorkspaceKind(configuration.kind)
        }
        guard let uri = WorkspaceURI(parsing: configuration.uri) else {
            throw NodeRuntimeError.invalidWorkspaceURI(configuration.id)
        }
        // The runtime cannot know a legacy adapter's tools, so it must not
        // invent any. An adapter that projects the reference it is handed
        // would otherwise advertise tools belonging to another implementation.
        // NodeAssembly derives the advertised reference from `listTools()`.
        return try factory(configuration, WorkspaceReference(
            id: configuration.id,
            uri: uri,
            location: .runtime,
            tools: []
        ))
    }

    func usesProductFactory(kind: String) -> Bool {
        productFactories[kind] != nil
    }

    func validate(kinds: some Sequence<String>) throws {
        for kind in kinds where factories[kind] == nil && productFactories[kind] == nil {
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

    public init(
        ascendants: AscendantAdapterRegistry = .init(),
        workspaces: WorkspaceAdapterRegistry = .init(),
        lifecycle: NodeRuntimeLifecycleHooks = .init()
    ) {
        self.ascendants = ascendants
        self.workspaces = workspaces
        self.lifecycle = lifecycle
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
    /// was constructed with, so it advertises the same tools through both the
    /// product and the legacy registration seams.
    public func listTools() async throws -> [ToolReference] { Self.toolDefinitions }

    public func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard id == Self.toolID else { throw WorkspaceError.toolExecutionNotSupported }
        return .success(parameters["value"]?.value as? String ?? "")
    }

    public func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    public func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public func listFiles(path _: String) async throws -> [String] { [] }
    public func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public func healthCheck() async -> Bool { true }
}
