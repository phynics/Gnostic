// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// The safe subset of a Workspace tool definition advertised by Gnostic.
public struct GnosticWorkspaceTool: Codable, Sendable, Equatable {
    /// The stable tool identifier.
    public let id: String

    /// The display name of the tool.
    public let name: String

    /// The tool's user-facing description.
    public let toolDescription: String

    /// The tool's parameter schema.
    public let parametersSchema: [String: ManifestJSONValue]

    /// An optional usage example.
    public let usageExample: String?

    /// Whether execution requires user approval.
    public let requiresPermission: Bool

    /// Creates a safe tool projection.
    public init(definition: GnosticWorkspaceToolDefinition) {
        id = definition.id
        name = definition.name
        toolDescription = definition.description
        parametersSchema = definition.parametersSchema
        usageExample = definition.usageExample
        requiresPermission = definition.requiresPermission
    }
}

/// A safe network projection of a Gnostic Workspace reference.
public final class GnosticWorkspaceObject: CoatyObject {
    /// The protocol major carried by this advertisement.
    public let protocolMajor: Int

    /// The workspace URI, without any filesystem root path.
    public var uri: String

    /// Whether the workspace is available for use.
    public var isAvailable: Bool

    /// The workspace trust level.
    public var trustLevel: GnosticWorkspaceTrustLevel

    /// The workspace lifecycle status.
    public var status: GnosticWorkspaceStatus

    /// The safe custom tool definitions exposed by this workspace.
    public var tools: [GnosticWorkspaceTool]

    /// The workspace creation timestamp.
    public var createdAt: Date

    /// Registers Gnostic's canonical workspace object type.
    public override class var objectType: String {
        register(objectType: GnosticObjectType.workspace, with: self)
    }

    /// Creates a safe Axoloty projection of a Workspace reference.
    public init(workspace: GnosticWorkspaceReference, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        uri = workspace.uri
        isAvailable = workspace.status == .active
        trustLevel = workspace.trustLevel
        status = workspace.status
        tools = workspace.tools.map(GnosticWorkspaceTool.init)
        createdAt = workspace.createdAt
        super.init(
            coreType: .CoatyObject,
            objectType: Self.objectType,
            objectId: CoatyUUID(uuidString: workspace.id.uuidString)!,
            name: workspace.uri
        )
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case protocolMajor
        case isAvailable
        case trustLevel
        case status
        case tools
        case createdAt
    }

    /// Decodes an advertised workspace projection.
    ///
    /// - Parameter decoder: The source decoder.
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        uri = try container.decode(String.self, forKey: .uri)
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
        trustLevel = try container.decodeIfPresent(GnosticWorkspaceTrustLevel.self, forKey: .trustLevel) ?? .full
        status = try container.decodeIfPresent(GnosticWorkspaceStatus.self, forKey: .status) ?? .unknown
        tools = try container.decode([GnosticWorkspaceTool].self, forKey: .tools)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        try super.init(from: decoder)
    }

    /// Encodes the safe workspace projection.
    ///
    /// - Parameter encoder: The destination encoder.
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(uri, forKey: .uri)
        try container.encode(isAvailable, forKey: .isAvailable)
        try container.encode(trustLevel, forKey: .trustLevel)
        try container.encode(status, forKey: .status)
        try container.encode(tools, forKey: .tools)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
