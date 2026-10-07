// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// Converts between the backend-neutral Workspace contract and the
/// Gnostic-owned network projection.
///
/// The conversion is intentionally lossless only in the Gnostic direction: the
/// backend contract carries the fields the kernel routes on, and the network
/// projection is derived from them. Provider-native conversion lives in the
/// backend that owns the provider dependency.
public enum WorkspaceReferenceProjection {
    /// Failures that prevent a projection.
    public enum Error: Swift.Error, Sendable, Equatable {
        /// The reference carried a URI the Gnostic grammar rejects.
        case invalidURI
    }

    /// Converts a backend Workspace value into the Gnostic-owned network shape.
    ///
    /// - Parameters:
    ///   - reference: The backend's view of the Workspace.
    ///   - effectiveStatus: An override for the derived effective status.
    /// - Returns: The Gnostic-owned network projection.
    public static func networkReference(
        from reference: BackendWorkspaceReference,
        effectiveStatus: GnosticWorkspaceEffectiveStatus? = nil
    ) -> GnosticWorkspaceReference {
        let providerStatus: GnosticWorkspaceStatus = switch reference.status {
        case .available: .active
        case .unavailable: .missing
        case .unsupported: .unknown
        }
        return GnosticWorkspaceReference(
            id: reference.id,
            uri: reference.uri,
            location: reference.location,
            trustLevel: .full,
            status: providerStatus,
            effectiveStatus: effectiveStatus ?? GnosticWorkspaceEffectiveStatus(providerStatus: providerStatus),
            tools: reference.tools.map { tool in
                GnosticWorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.description,
                    parametersSchema: parametersSchema(tool.parametersSchema),
                    usageExample: nil,
                    requiresPermission: tool.requiresPermission
                )
            },
            createdAt: reference.createdAt
        )
    }

    /// Converts a Gnostic network descriptor into the backend-neutral view the
    /// kernel routes on.
    ///
    /// - Parameter descriptor: The advertised network Workspace.
    /// - Returns: The backend-neutral Workspace reference.
    public static func backendReference(from descriptor: NetworkWorkspaceDescriptor) -> BackendWorkspaceReference {
        let status: BackendWorkspaceStatus = switch descriptor.effectiveStatus {
        case .available: .available
        case .unavailable: .unavailable
        case .unsupported: .unsupported
        }
        return BackendWorkspaceReference(
            id: descriptor.id,
            uri: descriptor.uri,
            status: status,
            tools: descriptor.tools.map { tool in
                BackendWorkspaceTool(
                    id: tool.id,
                    name: tool.name,
                    description: tool.toolDescription,
                    parametersSchema: .object(tool.parametersSchema),
                    requiresPermission: tool.requiresPermission
                )
            },
            location: .runtime,
            createdAt: descriptor.createdAt
        )
    }

    private static func parametersSchema(_ schema: ManifestJSONValue?) -> [String: ManifestJSONValue] {
        guard case let .object(value)? = schema else { return [:] }
        return value
    }
}
