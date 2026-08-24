// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The trust boundary advertised for a Gnostic Workspace.
public enum GnosticWorkspaceTrustLevel: String, Codable, Sendable, Equatable {
    /// Unrestricted operations within the Workspace boundary.
    case full
    /// Only an allowlisted set of operations is permitted.
    case restricted
    /// Only read-only filesystem operations are permitted.
    case readOnly
}

/// The provider-owned lifecycle state advertised for a Workspace.
public enum GnosticWorkspaceStatus: String, Codable, Sendable, Equatable {
    /// The Workspace is present and usable.
    case active
    /// The Workspace's underlying location could not be found.
    case missing
    /// The provider has not determined the Workspace state.
    case unknown
}

/// The Gnostic-owned placement of a Workspace relative to its runtime.
public enum GnosticWorkspaceLocation: String, Codable, Sendable, Equatable {
    /// A Workspace owned directly by the runtime.
    case runtime
    /// A Workspace specific to a runtime thread.
    case runtimeThread
    /// A Workspace attached from outside the runtime.
    case attached
}

/// A Gnostic-owned custom tool definition for a Workspace capability.
public struct GnosticWorkspaceToolDefinition: Codable, Sendable, Equatable {
    /// The stable tool identifier.
    public let id: String

    /// The display name of the tool.
    public let name: String

    /// The user-facing description of the tool.
    public let description: String

    /// The tool's parameter schema.
    public let parametersSchema: [String: ManifestJSONValue]

    /// An optional usage example.
    public let usageExample: String?

    /// Whether execution requires user approval.
    public let requiresPermission: Bool

    /// The stable tool identifier used by Workspace invocation paths.
    public var toolID: String { id }

    public init(
        id: String,
        name: String,
        description: String,
        parametersSchema: [String: ManifestJSONValue] = [:],
        usageExample: String? = nil,
        requiresPermission: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.usageExample = usageExample
        self.requiresPermission = requiresPermission
    }
}

/// The safe Workspace metadata used by Gnostic-owned projections.
public struct GnosticWorkspaceReference: Codable, Sendable, Equatable {
    /// The stable Workspace identifier.
    public let id: UUID

    /// The durable Workspace URI.
    public let uri: String

    /// The Workspace placement relative to its runtime.
    public let location: GnosticWorkspaceLocation

    /// The trust boundary advertised for this Workspace.
    public let trustLevel: GnosticWorkspaceTrustLevel

    /// The provider-owned lifecycle state.
    public let status: GnosticWorkspaceStatus

    /// The custom tools exposed by this Workspace.
    public let tools: [GnosticWorkspaceToolDefinition]

    /// The Workspace creation timestamp.
    public let createdAt: Date

    public init(
        id: UUID,
        uri: String,
        location: GnosticWorkspaceLocation = .runtime,
        trustLevel: GnosticWorkspaceTrustLevel = .full,
        status: GnosticWorkspaceStatus = .active,
        tools: [GnosticWorkspaceToolDefinition] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.uri = uri
        self.location = location
        self.trustLevel = trustLevel
        self.status = status
        self.tools = tools
        self.createdAt = createdAt
    }
}
