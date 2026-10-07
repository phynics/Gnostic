// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol
import PKContracts
import PositronicKit

/// Converts between Gnostic's provider-neutral Workspace projections and the
/// PositronicKit values the bundled backend consumes.
///
/// This is the Positronic half of the projection. The kernel keeps the
/// provider-neutral half in `GnosticCore.WorkspaceReferenceProjection`; native
/// values never cross back into the kernel.
public enum PositronicWorkspaceProjection {
    /// Failures that prevent a projection.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The reference carried a URI the Gnostic grammar rejects.
        case invalidURI
    }

    /// Converts a PositronicKit Workspace value into the Gnostic-owned network
    /// shape used by advertisement callers.
    ///
    /// - Parameters:
    ///   - reference: The PositronicKit Workspace reference.
    ///   - effectiveStatus: An override for the derived effective status.
    /// - Returns: The Gnostic-owned network projection.
    public static func networkReference(
        from reference: WorkspaceReference,
        effectiveStatus: GnosticWorkspaceEffectiveStatus? = nil
    ) -> GnosticWorkspaceReference {
        let providerStatus = GnosticWorkspaceStatus(rawValue: reference.status.rawValue) ?? .unknown
        return GnosticWorkspaceReference(
            id: reference.id,
            uri: reference.uri.description,
            location: GnosticWorkspaceLocation(rawValue: reference.location.rawValue) ?? .runtime,
            trustLevel: .full,
            status: providerStatus,
            effectiveStatus: effectiveStatus ?? GnosticWorkspaceEffectiveStatus(providerStatus: providerStatus),
            tools: reference.tools.compactMap { tool in
                guard case let .custom(definition) = tool else { return nil }
                return GnosticWorkspaceToolDefinition(
                    id: definition.id,
                    name: definition.name,
                    description: definition.description,
                    parametersSchema: definition.parametersSchema.mapValues(Self.manifestValue),
                    usageExample: definition.usageExample,
                    requiresPermission: definition.requiresPermission
                )
            },
            createdAt: reference.createdAt
        )
    }

    /// Converts a PositronicKit Workspace value into the kernel's backend-neutral
    /// reference.
    ///
    /// - Parameter reference: The PositronicKit Workspace reference.
    /// - Returns: The backend-neutral Workspace reference.
    public static func backendReference(from reference: WorkspaceReference) -> BackendWorkspaceReference {
        BackendWorkspaceReference(
            id: reference.id,
            uri: reference.uri.description,
            status: BackendWorkspaceStatus(rawValue: reference.status.rawValue) ?? .unavailable,
            tools: reference.tools.compactMap { tool -> BackendWorkspaceTool? in
                guard case let .custom(definition) = tool else { return nil }
                return BackendWorkspaceTool(
                    id: definition.id,
                    name: definition.name,
                    description: definition.description,
                    parametersSchema: .object(definition.parametersSchema.mapValues(Self.manifestValue)),
                    requiresPermission: definition.requiresPermission
                )
            },
            location: GnosticWorkspaceLocation(rawValue: reference.location.rawValue) ?? .runtime,
            createdAt: reference.createdAt
        )
    }

    /// Converts a Gnostic network descriptor into the PositronicKit runtime
    /// value required by an explicit host adapter.
    ///
    /// - Parameter descriptor: The advertised network Workspace.
    /// - Returns: The PositronicKit Workspace reference.
    /// - Throws: ``Error/invalidURI`` when the descriptor URI is unparseable.
    public static func reference(from descriptor: NetworkWorkspaceDescriptor) throws -> WorkspaceReference {
        let status: GnosticWorkspaceStatus
        if descriptor.status == .unknown, descriptor.isAvailable {
            status = .active
        } else {
            status = descriptor.status
        }
        return try reference(from: GnosticWorkspaceReference(
            id: descriptor.id,
            uri: descriptor.uri,
            trustLevel: descriptor.trustLevel,
            status: status,
            effectiveStatus: descriptor.effectiveStatus,
            tools: descriptor.tools.map { tool in
                GnosticWorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.toolDescription,
                    parametersSchema: tool.parametersSchema,
                    usageExample: tool.usageExample,
                    requiresPermission: tool.requiresPermission
                )
            },
            createdAt: descriptor.createdAt
        ))
    }

    /// Converts a Gnostic Workspace reference into the PositronicKit runtime
    /// value required by an explicit host adapter.
    ///
    /// - Parameter reference: The Gnostic-owned network projection.
    /// - Returns: The PositronicKit Workspace reference.
    /// - Throws: ``Error/invalidURI`` when the reference URI is unparseable.
    public static func reference(from reference: GnosticWorkspaceReference) throws -> WorkspaceReference {
        guard let uri = WorkspaceURI(parsing: reference.uri) else {
            throw Error.invalidURI
        }
        let status = WorkspaceReference.WorkspaceStatus(rawValue: reference.status.rawValue) ?? .unknown
        return WorkspaceReference(
            id: reference.id,
            uri: uri,
            location: WorkspaceReference.WorkspaceLocation(rawValue: reference.location.rawValue) ?? .runtime,
            tools: reference.tools.map { tool in
                .custom(WorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.description,
                    parametersSchema: tool.parametersSchema.mapValues(Self.anyCodable),
                    usageExample: tool.usageExample,
                    requiresPermission: tool.requiresPermission
                ))
            },
            status: status,
            createdAt: reference.createdAt
        )
    }

    static func manifestValue(_ value: AnyCodable) -> ManifestJSONValue {
        if let value = value.value as? String { return .string(value) }
        if let value = value.value as? Bool { return .bool(value) }
        if let value = value.value as? Int { return .number(Double(value)) }
        if let value = value.value as? Int64 { return .number(Double(value)) }
        if let value = value.value as? UInt64 { return .number(Double(value)) }
        if let value = value.value as? Double { return .number(value) }
        if let value = value.value as? Float { return .number(Double(value)) }
        if let value = value.value as? [String: AnyCodable] {
            return .object(value.mapValues(Self.manifestValue))
        }
        if let value = value.value as? [AnyCodable] {
            return .array(value.map(Self.manifestValue))
        }
        if let data = try? JSONEncoder().encode(value),
           let decoded = try? JSONDecoder().decode(ManifestJSONValue.self, from: data) {
            return decoded
        }
        return .null
    }

    private static func anyCodable(_ value: ManifestJSONValue) -> AnyCodable {
        switch value {
        case let .string(value): return AnyCodable(value)
        case let .number(value): return AnyCodable(value)
        case let .bool(value): return AnyCodable(value)
        case let .object(value): return AnyCodable(value.mapValues(Self.anyCodable))
        case let .array(value): return AnyCodable(value.map(Self.anyCodable))
        case .null: return AnyCodable(NSNull())
        }
    }
}

/// Bridges the released PositronicKit reference into Gnostic's transport projection.
public extension GnosticWorkspaceObject {
    convenience init(workspace: WorkspaceReference, protocolMajor: Int = GnosticProtocol.currentMajor, includeTools: Bool = true) {
        self.init(workspace: PositronicWorkspaceProjection.networkReference(from: workspace), protocolMajor: protocolMajor, includeTools: includeTools)
    }
}

/// Bridges PositronicKit tool definitions into query-only Gnostic objects.
public extension GnosticWorkspaceToolObject {
    convenience init(workspaceID: UUID, definition: WorkspaceToolDefinition, page: Int = 0, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.init(
            workspaceID: workspaceID,
            definition: GnosticWorkspaceToolDefinition(
                id: definition.id,
                name: definition.name,
                description: definition.description,
                parametersSchema: definition.parametersSchema.mapValues(PositronicWorkspaceProjection.manifestValue),
                usageExample: definition.usageExample,
                requiresPermission: definition.requiresPermission
            ),
            page: page,
            protocolMajor: protocolMajor
        )
    }
}
