// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

extension BackendWorkspaceReference {
    init(reference: WorkspaceReference, status: BackendWorkspaceStatus = .available) {
        self.init(
            id: reference.id,
            uri: reference.uri.description,
            status: status,
            tools: reference.tools.compactMap {
                guard case let .custom(definition) = $0 else { return nil }
                return BackendWorkspaceTool(
                    id: definition.id,
                    name: definition.name,
                    description: definition.description,
                    parametersSchema: .object(definition.parametersSchema.mapValues { value in
                        if let string = value.value as? String { return .string(string) }
                        if let bool = value.value as? Bool { return .bool(bool) }
                        if let number = value.value as? Int { return .number(Double(number)) }
                        if let number = value.value as? Double { return .number(number) }
                        return .null
                    }),
                    requiresPermission: definition.requiresPermission
                )
            }
        )
    }
}

/// Optional file operations exposed by a Workspace host. They are kept out of
/// the mandatory backend contract because remote capability Workspaces need
/// not be filesystems.
@MainActor
public protocol AscendantBackendWorkspaceFileService: Sendable {
    func readFile(workspaceID: UUID, path: String) async throws -> String
    func writeFile(workspaceID: UUID, path: String, content: String) async throws
    func listFiles(workspaceID: UUID, path: String) async throws -> [String]
    func deleteFile(workspaceID: UUID, path: String) async throws
}

/// Gnostic's host-owned Workspace consumption service. Axoloty catalogs and
/// Positronic workspace values are deliberately confined to this host bridge;
/// the ``AscendantBackendWorkspaceService`` contract remains Foundation-only.
@MainActor
final class GnosticWorkspaceBackendService: AscendantBackendWorkspaceService, AscendantBackendWorkspaceFileService, @unchecked Sendable {
    private let localWorkspaces: [UUID: any Workspace]
    private var references: [UUID: WorkspaceReference]
    private let catalog: NetworkCatalog
    private let communication: CommunicationManager

    init(
        localWorkspaces: [UUID: any Workspace],
        references: [UUID: WorkspaceReference],
        catalog: NetworkCatalog,
        communication: CommunicationManager
    ) {
        self.localWorkspaces = localWorkspaces
        self.references = references
        self.catalog = catalog
        self.communication = communication
    }

    func update(reference: WorkspaceReference) {
        references[reference.id] = reference
    }

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        if let reference = references[id] {
            let status: BackendWorkspaceStatus
            if localWorkspaces[id] != nil {
                status = .available
            } else {
                status = await networkStatus(id: id)
            }
            return Self.backendReference(reference, status: status)
        }
        guard case let .available(providerID, uri) = await catalog.workspaceAttachmentStatus(id: id),
              let descriptor = await catalog.object(id: id, providerID: providerID)?.workspace else {
            return nil
        }
        return BackendWorkspaceReference(
            id: id,
            uri: uri,
            status: descriptor.isAvailable ? .available : .unavailable,
            tools: descriptor.tools.map(Self.backendTool)
        )
    }

    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        guard let reference = await reference(id: invocation.workspaceID), reference.status == .available else {
            throw AscendantBackendError.invalidConfiguration("Workspace \(invocation.workspaceID.uuidString) is unavailable.")
        }
        guard reference.tools.contains(where: { $0.id == invocation.toolID }) else {
            throw AscendantBackendError.invalidConfiguration("Workspace tool '\(invocation.toolID)' is unsupported.")
        }
        let parameters = invocation.arguments.reduce(into: [String: AnyCodable]()) { result, pair in
            result[pair.key] = AnyCodable(Self.anyValue(pair.value))
        }
        let toolResult: ToolResult
        if let local = localWorkspaces[invocation.workspaceID] {
            toolResult = try await local.executeTool(id: invocation.toolID, parameters: parameters)
        } else {
            let proxy = AxolotyWorkspace(
                reference: try Self.positronicReference(reference),
                catalog: catalog,
                communication: communication
            )
            toolResult = try await proxy.executeTool(id: invocation.toolID, parameters: parameters)
        }
        return BackendWorkspaceResult(message: String(describing: toolResult))
    }

    func readFile(workspaceID: UUID, path: String) async throws -> String {
        guard let workspace = localWorkspaces[workspaceID] else { throw WorkspaceError.toolExecutionNotSupported }
        return try await workspace.readFile(path: path)
    }

    func writeFile(workspaceID: UUID, path: String, content: String) async throws {
        guard let workspace = localWorkspaces[workspaceID] else { throw WorkspaceError.toolExecutionNotSupported }
        try await workspace.writeFile(path: path, content: content)
    }

    func listFiles(workspaceID: UUID, path: String) async throws -> [String] {
        guard let workspace = localWorkspaces[workspaceID] else { throw WorkspaceError.toolExecutionNotSupported }
        return try await workspace.listFiles(path: path)
    }

    func deleteFile(workspaceID: UUID, path: String) async throws {
        guard let workspace = localWorkspaces[workspaceID] else { throw WorkspaceError.toolExecutionNotSupported }
        try await workspace.deleteFile(path: path)
    }

    private func networkStatus(id: UUID) async -> BackendWorkspaceStatus {
        switch await catalog.workspaceAttachmentStatus(id: id) {
        case .available: return .available
        case .unavailable: return .unavailable
        case .ambiguous, .malformed: return .unsupported
        }
    }

    private static func backendReference(_ reference: WorkspaceReference, status: BackendWorkspaceStatus) -> BackendWorkspaceReference {
        BackendWorkspaceReference(
            id: reference.id,
            uri: reference.uri.description,
            status: status,
            tools: reference.tools.compactMap {
                guard case let .custom(definition) = $0 else { return nil }
                return backendTool(definition)
            }
        )
    }

    private static func backendTool(_ definition: WorkspaceToolDefinition) -> BackendWorkspaceTool {
        BackendWorkspaceTool(
            id: definition.id,
            name: definition.name,
            description: definition.description,
            parametersSchema: .object(definition.parametersSchema.mapValues { manifestValue($0) }),
            requiresPermission: definition.requiresPermission
        )
    }

    private static func manifestValue(_ value: AnyCodable) -> ManifestJSONValue {
        if let value = value.value as? String { return .string(value) }
        if let value = value.value as? Bool { return .bool(value) }
        if let value = value.value as? Int { return .number(Double(value)) }
        if let value = value.value as? Double { return .number(value) }
        if let value = value.value as? [String: AnyCodable] {
            return .object(value.mapValues(manifestValue))
        }
        if let value = value.value as? [AnyCodable] {
            return .array(value.map(manifestValue))
        }
        return .null
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

    private static func positronicReference(_ reference: BackendWorkspaceReference) throws -> WorkspaceReference {
        guard let uri = WorkspaceURI(parsing: reference.uri) else {
            throw AscendantBackendError.invalidConfiguration("Invalid Workspace URI '\(reference.uri)'.")
        }
        return WorkspaceReference(
            id: reference.id,
            uri: uri,
            location: .runtime,
            tools: reference.tools.map {
                .custom(WorkspaceToolDefinition(
                    id: $0.id,
                    name: $0.name,
                    description: $0.description,
                    parametersSchema: {
                        guard let schema = $0.parametersSchema, case let .object(values) = schema else { return [:] }
                        return values.mapValues { AnyCodable(anyValue($0)) }
                    }(),
                    requiresPermission: $0.requiresPermission
                ))
            }
        )
    }
}
