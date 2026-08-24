// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts

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

/// The Gnostic-owned effective usability of a Workspace attachment.
public enum GnosticWorkspaceEffectiveStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// The Workspace is currently safe to use.
    case available
    /// The intended Workspace is known but cannot currently be used.
    case unavailable
    /// The Workspace cannot safely be used by this runtime or protocol.
    case unsupported

    /// Derives effective usability from a provider lifecycle projection.
    public init(providerStatus: GnosticWorkspaceStatus) {
        switch providerStatus {
        case .active: self = .available
        case .missing: self = .unavailable
        case .unknown: self = .unavailable
        }
    }
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
    public let parametersSchema: [String: AnyCodable]

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
        parametersSchema: [String: AnyCodable] = [:],
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

    /// The Gnostic-owned effective usability of this Workspace.
    public let effectiveStatus: GnosticWorkspaceEffectiveStatus

    /// The custom tools exposed by this Workspace.
    public let tools: [GnosticWorkspaceToolDefinition]

    /// The Workspace creation timestamp.
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, uri, location, trustLevel, status, effectiveStatus, tools, createdAt
    }

    public init(
        id: UUID,
        uri: String,
        location: GnosticWorkspaceLocation = .runtime,
        trustLevel: GnosticWorkspaceTrustLevel = .full,
        status: GnosticWorkspaceStatus = .active,
        effectiveStatus: GnosticWorkspaceEffectiveStatus? = nil,
        tools: [GnosticWorkspaceToolDefinition] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.uri = uri
        self.location = location
        self.trustLevel = trustLevel
        self.status = status
        self.effectiveStatus = effectiveStatus ?? GnosticWorkspaceEffectiveStatus(providerStatus: status)
        self.tools = tools
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decodeIfPresent(GnosticWorkspaceStatus.self, forKey: .status) ?? .unknown
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            uri: try container.decode(String.self, forKey: .uri),
            location: try container.decodeIfPresent(GnosticWorkspaceLocation.self, forKey: .location) ?? .runtime,
            trustLevel: try container.decodeIfPresent(GnosticWorkspaceTrustLevel.self, forKey: .trustLevel) ?? .full,
            status: status,
            effectiveStatus: try container.decodeIfPresent(GnosticWorkspaceEffectiveStatus.self, forKey: .effectiveStatus),
            tools: try container.decodeIfPresent([GnosticWorkspaceToolDefinition].self, forKey: .tools) ?? [],
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(uri, forKey: .uri)
        try container.encode(location, forKey: .location)
        try container.encode(trustLevel, forKey: .trustLevel)
        try container.encode(status, forKey: .status)
        try container.encode(effectiveStatus, forKey: .effectiveStatus)
        try container.encode(tools, forKey: .tools)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
