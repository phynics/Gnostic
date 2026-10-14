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
                    parametersSchema: definition.parametersSchema.mapValues(PositronicJSONValueBridge.manifestValue),
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
        let status: BackendWorkspaceStatus = switch reference.status {
        case .active: .available
        case .missing: .unavailable
        case .unknown: .unavailable
        }
        return BackendWorkspaceReference(
            id: reference.id,
            uri: reference.uri.description,
            status: status,
            tools: reference.tools.compactMap { tool -> BackendWorkspaceTool? in
                guard case let .custom(definition) = tool else { return nil }
                return BackendWorkspaceTool(
                    id: definition.id,
                    name: definition.name,
                    description: definition.description,
                    parametersSchema: .object(definition.parametersSchema.mapValues(PositronicJSONValueBridge.manifestValue)),
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
        try buildReference(
            id: reference.id,
            uri: reference.uri,
            location: reference.location,
            status: WorkspaceReference.WorkspaceStatus(rawValue: reference.status.rawValue) ?? .unknown,
            definitions: reference.tools.map { tool in
                WorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.description,
                    parametersSchema: tool.parametersSchema.mapValues(PositronicJSONValueBridge.anyCodable),
                    usageExample: tool.usageExample,
                    requiresPermission: tool.requiresPermission
                )
            },
            createdAt: reference.createdAt
        )
    }

    /// Converts a Gnostic backend Workspace reference into the PositronicKit
    /// runtime value required by an explicit host adapter.
    ///
    /// The backend contract carries effective usability, while PositronicKit
    /// carries the provider lifecycle state, so `available` maps to `active`,
    /// `unavailable` to `missing`, and `unsupported` to `unknown`. The location
    /// uses the same `.runtime` fallback as every other reference conversion.
    ///
    /// - Parameter reference: The backend's view of the Workspace.
    /// - Returns: The PositronicKit Workspace reference.
    /// - Throws: ``Error/invalidURI`` when the reference URI is unparseable.
    public static func reference(from reference: BackendWorkspaceReference) throws -> WorkspaceReference {
        let status: WorkspaceReference.WorkspaceStatus = switch reference.status {
        case .available: .active
        case .unavailable: .missing
        case .unsupported: .unknown
        }
        return try buildReference(
            id: reference.id,
            uri: reference.uri,
            location: reference.location,
            status: status,
            definitions: reference.tools.map { tool in
                WorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.description,
                    parametersSchema: parameters(of: tool).mapValues(PositronicJSONValueBridge.anyCodable),
                    requiresPermission: tool.requiresPermission
                )
            },
            createdAt: reference.createdAt
        )
    }

    /// Builds the PositronicKit Workspace reference from already-projected parts.
    ///
    /// Both public `reference(from:)` overloads route here so the URI grammar and
    /// the `.runtime` location fallback live in exactly one place.
    private static func buildReference(
        id: UUID,
        uri: String,
        location: GnosticWorkspaceLocation,
        status: WorkspaceReference.WorkspaceStatus,
        definitions: [WorkspaceToolDefinition],
        createdAt: Date
    ) throws -> WorkspaceReference {
        guard let parsed = WorkspaceURI(parsing: uri) else {
            throw Error.invalidURI
        }
        return WorkspaceReference(
            id: id,
            uri: parsed,
            location: WorkspaceReference.WorkspaceLocation(rawValue: location.rawValue) ?? .runtime,
            tools: definitions.map { ToolReference.custom($0) },
            status: status,
            createdAt: createdAt
        )
    }

    /// Returns the object-shaped tool parameters, or an empty map when the
    /// backend advertises no schema.
    private static func parameters(of tool: BackendWorkspaceTool) -> [String: ManifestJSONValue] {
        guard let schema = tool.parametersSchema, case let .object(values) = schema else { return [:] }
        return values
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
                parametersSchema: definition.parametersSchema.mapValues(PositronicJSONValueBridge.manifestValue),
                usageExample: definition.usageExample,
                requiresPermission: definition.requiresPermission
            ),
            page: page,
            protocolMajor: protocolMajor
        )
    }
}
