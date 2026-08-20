// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

public struct AscendantAdapterRegistry: Sendable {
    /// Compatibility factory shape for adapters registered before RESET-004.
    public typealias Factory = @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration, _ dependencies: AscendantRuntimeDependencies, _ timelines: [NodeManifest.Timeline], _ references: [UUID: WorkspaceReference]) async throws -> any AscendantRuntimeAdapter
    public typealias BackendFactory = @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration, _ services: AscendantBackendServices, _ timelines: [NodeManifest.Timeline]) async throws -> any AscendantBackend

    private enum RegisteredFactory: Sendable {
        case backend(BackendFactory)
        case legacy(Factory)
    }

    private var factories: [String: RegisteredFactory]

    public init() {
        factories = ["positronic": .backend({ ascendant, backend, services, timelines in
            try await PositronicAscendantAdapter(ascendant: ascendant, backend: backend, services: services, timelines: timelines, languageModel: UnconfiguredLLMService())
        })]
    }

    /// Registers the backend-neutral contract. This is the only supported
    /// selection point for a backend kind in new code.
    public mutating func registerBackend<B: AscendantBackend>(
        kind: String,
        factory: @escaping @MainActor @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration, _ services: AscendantBackendServices, _ timelines: [NodeManifest.Timeline]) async throws -> B
    ) {
        factories[kind] = .backend({ ascendant, backend, services, timelines in
            try await factory(ascendant, backend, services, timelines)
        })
    }

    public mutating func registerBackend(kind: String, factory: @escaping BackendFactory) {
        factories[kind] = .backend(factory)
    }

    /// Compatibility registration for the pre-RESET-004 adapter surface.
    public mutating func register(kind: String, factory: @escaping Factory) {
        factories[kind] = .legacy(factory)
    }

    /// Familiar registration label for backend-neutral implementations.
    public mutating func register(kind: String, factory: @escaping BackendFactory) {
        factories[kind] = .backend(factory)
    }

    /// Transitional composition seam for the CLI. Backend semantics remain
    /// outside Core; the closure receives only the opaque envelope.
    public mutating func register(kind: String, languageModel factory: @escaping @Sendable (_ ascendant: NodeManifest.Ascendant, _ backend: AscendantBackendConfiguration) -> any LanguageModel) {
        factories[kind] = .backend({ ascendant, backend, services, timelines in
            try await PositronicAscendantAdapter(ascendant: ascendant, backend: backend, services: services, timelines: timelines, languageModel: factory(ascendant, backend))
        })
    }

    @MainActor
    func makeBackend(for ascendant: NodeManifest.Ascendant, backend: AscendantBackendConfiguration, services: AscendantBackendServices, timelines: [NodeManifest.Timeline]) async throws -> any AscendantBackend {
        try AscendantBackendConfigurationValidator.validate(backend)
        guard let factory = factories[backend.kind] else { throw NodeRuntimeError.unsupportedAscendantKind(backend.kind) }
        switch factory {
        case let .backend(factory):
            return try await factory(ascendant, backend, services, timelines)
        case let .legacy(factory):
            let dependencies = AscendantRuntimeDependencies(services: services)
            var legacyReferences: [UUID: WorkspaceReference] = [:]
            for timeline in timelines {
                for attachment in timeline.attachments {
                    guard legacyReferences[attachment.workspaceID] == nil,
                          let workspace = services.workspace,
                          let reference = await workspace.reference(id: attachment.workspaceID),
                          let uri = WorkspaceURI(parsing: reference.uri) else { continue }
                    legacyReferences[attachment.workspaceID] = WorkspaceReference(
                        id: attachment.workspaceID,
                        uri: uri,
                        location: .runtime,
                        tools: reference.tools.map { tool in
                            .custom(WorkspaceToolDefinition(
                                id: tool.id,
                                name: tool.name,
                                description: tool.description,
                                parametersSchema: Self.schemaValues(tool.parametersSchema),
                                requiresPermission: tool.requiresPermission
                            ))
                        }
                    )
                }
            }
            return LegacyAscendantBackendBridge(adapter: try await factory(ascendant, backend, dependencies, timelines, legacyReferences))
        }
    }

    private static func schemaValues(_ value: ManifestJSONValue?) -> [String: AnyCodable] {
        guard let value, case let .object(values) = value else { return [:] }
        return values.mapValues { AnyCodable(anyValue($0)) }
    }

    private static func anyValue(_ value: ManifestJSONValue) -> Any {
        switch value {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues(anyValue)
        case let .array(value): return value.map(anyValue)
        case .null: return NSNull()
        }
    }

    func validate(kinds: some Sequence<String>) throws {
        for kind in kinds where factories[kind] == nil {
            throw NodeRuntimeError.unsupportedAscendantKind(kind)
        }
    }
}

/// A registry of local Workspace adapters keyed by the manifest's `kind` field.
public struct WorkspaceAdapterRegistry: Sendable {
    public typealias Factory = @Sendable (_ configuration: NodeManifest.Workspace, _ reference: WorkspaceReference) throws -> any Workspace

    private var factories: [String: Factory]

    public init() {
        factories = ["echo": { _, reference in EchoWorkspace(reference: reference) }]
    }

    public mutating func register(kind: String, factory: @escaping Factory) {
        factories[kind] = factory
    }

    func makeWorkspace(for configuration: NodeManifest.Workspace, reference: WorkspaceReference) throws -> any Workspace {
        guard let factory = factories[configuration.kind] else { throw NodeRuntimeError.unsupportedWorkspaceKind(configuration.kind) }
        return try factory(configuration, reference)
    }

    func validate(kinds: some Sequence<String>) throws {
        for kind in kinds where factories[kind] == nil {
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
public struct EchoWorkspace: Workspace, Sendable {
    public let reference: WorkspaceReference
    public var id: UUID { reference.id }

    public init(reference: WorkspaceReference) { self.reference = reference }

    public func listTools() async throws -> [ToolReference] { reference.tools }

    public func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard id == NodeRuntime.echoToolID else { throw WorkspaceError.toolExecutionNotSupported }
        return .success(parameters["value"]?.value as? String ?? "")
    }

    public func readFile(path _: String) async throws -> String { throw WorkspaceError.toolExecutionNotSupported }
    public func writeFile(path _: String, content _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public func listFiles(path _: String) async throws -> [String] { throw WorkspaceError.toolExecutionNotSupported }
    public func deleteFile(path _: String) async throws { throw WorkspaceError.toolExecutionNotSupported }
    public func healthCheck() async -> Bool { true }
}
