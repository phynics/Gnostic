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
    public static func networkReference(from reference: WorkspaceReference) -> GnosticWorkspaceReference {
        GnosticWorkspaceReference(
            id: reference.id,
            uri: reference.uri.description,
            location: GnosticWorkspaceLocation(rawValue: reference.location.rawValue) ?? .runtime,
            trustLevel: GnosticWorkspaceTrustLevel(rawValue: reference.trustLevel.rawValue) ?? .full,
            status: GnosticWorkspaceStatus(rawValue: reference.status.rawValue) ?? .unknown,
            tools: reference.tools.compactMap { tool in
                guard case let .custom(definition) = tool else { return nil }
                return GnosticWorkspaceToolDefinition(
                    id: definition.id,
                    name: definition.name,
                    description: definition.description,
                    parametersSchema: definition.parametersSchema,
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
                    parametersSchema: tool.parametersSchema,
                    usageExample: tool.usageExample,
                    requiresPermission: tool.requiresPermission
                ))
            },
            trustLevel: WorkspaceTrustLevel(rawValue: reference.trustLevel.rawValue) ?? .full,
            status: status,
            createdAt: reference.createdAt
        )
    }
}
