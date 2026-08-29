// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts
import PositronicKit

/// Converts a safe network descriptor into the runtime reference used by the
/// timeline manager and remote workspace proxy.
public enum WorkspaceReferenceProjection {
    public enum Error: Swift.Error, Sendable, Equatable {
        case invalidURI
    }

    /// Converts a runtime Workspace value into the Gnostic-owned network shape.
    /// This is the only conversion needed by network advertisement callers.
    public static func networkReference(
        from reference: WorkspaceReference,
        effectiveStatus: GnosticWorkspaceEffectiveStatus? = nil
    ) -> GnosticWorkspaceReference {
        let providerStatus = GnosticWorkspaceStatus(rawValue: reference.status.rawValue) ?? .unknown
        return GnosticWorkspaceReference(
            id: reference.id,
            uri: reference.uri.description,
            location: GnosticWorkspaceLocation(rawValue: reference.location.rawValue) ?? .runtime,
            trustLevel: GnosticWorkspaceTrustLevel(rawValue: reference.trustLevel.rawValue) ?? .full,
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

    /// Converts a Gnostic network descriptor into the PositronicKit runtime
    /// value required by an explicit host adapter.
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
            trustLevel: WorkspaceTrustLevel(rawValue: reference.trustLevel.rawValue) ?? .full,
            status: status,
            createdAt: reference.createdAt
        )
    }

    fileprivate static func manifestValue(_ value: AnyCodable) -> ManifestJSONValue {
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
        self.init(workspace: WorkspaceReferenceProjection.networkReference(from: workspace), protocolMajor: protocolMajor, includeTools: includeTools)
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
                parametersSchema: definition.parametersSchema.mapValues(WorkspaceReferenceProjection.manifestValue),
                usageExample: definition.usageExample,
                requiresPermission: definition.requiresPermission
            ),
            page: page,
            protocolMajor: protocolMajor
        )
    }
}
