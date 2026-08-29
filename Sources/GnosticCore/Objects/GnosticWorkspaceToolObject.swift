// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// A public Workspace tool returned by Axoloty Query/Retrieve.
///
/// Tool objects are intentionally queryable but never advertised. Their
/// parent object is the Workspace, so a consumer can retrieve the public tool
/// catalog without placing the dynamic catalog in the retained advertisement.
public final class GnosticWorkspaceToolObject: CoatyObject, @unchecked Sendable {
    public let protocolMajor: Int
    public let workspaceID: UUID
    public let toolID: String
    public let toolName: String
    public let toolDescription: String
    public let parametersSchema: [String: ManifestJSONValue]
    public let usageExample: String?
    public let requiresPermission: Bool
    public let page: Int
    /// True when the provider's schema was too large for a single tool object.
    /// The tool remains invocable; clients can treat an empty schema as opaque.
    public let schemaTruncated: Bool

    public override class var objectType: String {
        register(objectType: GnosticObjectType.workspaceTool, with: self)
    }

    public convenience init(workspaceID: UUID, definition: GnosticWorkspaceToolDefinition, page: Int = 0, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.init(
            workspaceID: workspaceID,
            toolID: definition.id,
            toolName: definition.name,
            toolDescription: definition.description,
            parametersSchema: definition.parametersSchema,
            usageExample: definition.usageExample,
            requiresPermission: definition.requiresPermission,
            page: page,
            protocolMajor: protocolMajor
        )
    }

    private init(workspaceID: UUID, toolID: String, toolName: String, toolDescription: String, parametersSchema: [String: ManifestJSONValue], usageExample: String?, requiresPermission: Bool, page: Int, protocolMajor: Int) {
        self.protocolMajor = protocolMajor
        self.workspaceID = workspaceID
        self.toolID = toolID
        self.toolName = GnosticWirePayload.boundedLabel(toolName)
        self.toolDescription = GnosticWirePayload.boundedLabel(toolDescription)
        let schemaData = try? JSONEncoder().encode(parametersSchema)
        schemaTruncated = schemaData.map { $0.count > 700 } ?? true
        self.parametersSchema = schemaTruncated ? [:] : parametersSchema
        self.usageExample = usageExample.map { GnosticWirePayload.boundedLabel($0) }
        self.requiresPermission = requiresPermission
        self.page = page
        super.init(
            coreType: .CoatyObject,
            objectType: Self.objectType,
            objectId: CoatyUUID(),
            name: GnosticWirePayload.boundedLabel(toolName)
        )
        parentObjectId = CoatyUUID(uuidString: workspaceID.uuidString)!
        externalId = toolID
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, workspaceID, toolID, toolName, toolDescription
        case parametersSchema, usageExample, requiresPermission, page, schemaTruncated
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        toolID = try container.decode(String.self, forKey: .toolID)
        toolName = GnosticWirePayload.boundedLabel(try container.decode(String.self, forKey: .toolName))
        toolDescription = GnosticWirePayload.boundedLabel(try container.decode(String.self, forKey: .toolDescription))
        parametersSchema = try container.decode([String: ManifestJSONValue].self, forKey: .parametersSchema)
        usageExample = try container.decodeIfPresent(String.self, forKey: .usageExample).map { GnosticWirePayload.boundedLabel($0) }
        requiresPermission = try container.decode(Bool.self, forKey: .requiresPermission)
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 0
        schemaTruncated = try container.decodeIfPresent(Bool.self, forKey: .schemaTruncated) ?? false
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(toolID, forKey: .toolID)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(toolDescription, forKey: .toolDescription)
        try container.encode(parametersSchema, forKey: .parametersSchema)
        try container.encodeIfPresent(usageExample, forKey: .usageExample)
        try container.encode(requiresPermission, forKey: .requiresPermission)
        try container.encode(page, forKey: .page)
        try container.encode(schemaTruncated, forKey: .schemaTruncated)
    }

    public var tool: GnosticWorkspaceTool {
        GnosticWorkspaceTool(
            id: toolID,
            name: toolName,
            toolDescription: toolDescription,
            parametersSchema: parametersSchema,
            usageExample: usageExample,
            requiresPermission: requiresPermission
        )
    }
}

private extension GnosticWorkspaceTool {
    init(id: String, name: String, toolDescription: String, parametersSchema: [String: ManifestJSONValue], usageExample: String?, requiresPermission: Bool) {
        self.id = id
        self.name = name
        self.toolDescription = toolDescription
        self.parametersSchema = parametersSchema
        self.usageExample = usageExample
        self.requiresPermission = requiresPermission
    }
}
