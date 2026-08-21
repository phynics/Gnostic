// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import JSONSchema
import JSONSchemaBuilder
import PKContracts
import PositronicKit

/// The `list_network_objects` PositronicKit tool.
public struct ListNetworkObjectsTool: Tool, Sendable {
    private let service: DiscoveredWorkspaceAttachmentService
    init(service: DiscoveredWorkspaceAttachmentService) { self.service = service }
    public let callName = "list_network_objects"
    public let name = "List network objects"
    public let description = "Lists currently advertised Gnostic network objects."
    public let requiresPermission = false
    public let sideEffects: ToolSideEffects = .none
    public var parametersSchema: Schema {
        ToolParameterSchema.object {}.schemaDefinition
    }
    public func canExecute() async -> Bool { true }
    public func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        let entries = await service.listNetworkObjects()
        return .success(entries.map { "\($0.objectID.uuidString) \($0.providerID) \($0.objectType) \($0.name)" }.joined(separator: "\n"))
    }
}

/// The `inspect_network_object` PositronicKit tool.
public struct InspectNetworkObjectTool: Tool, Sendable {
    private let service: DiscoveredWorkspaceAttachmentService
    init(service: DiscoveredWorkspaceAttachmentService) { self.service = service }
    public let callName = "inspect_network_object"
    public let name = "Inspect network object"
    public let description = "Inspects one provider-scoped advertised Gnostic object."
    public let requiresPermission = false
    public let sideEffects: ToolSideEffects = .none
    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "objectId") {
                JSONString().description("UUID of the advertised Gnostic object to inspect.")
            }.required()
            JSONProperty(key: "providerId") {
                JSONString().description("Provider ID returned by list_network_objects.")
            }.required()
        }.schemaDefinition
    }
    public func canExecute() async -> Bool { true }
    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard let rawID = parameters["objectId"]?.asString, let id = UUID(uuidString: rawID),
              let providerID = parameters["providerId"]?.asString else { return .failure("objectId and providerId are required") }
        guard let entry = await service.inspectNetworkObject(id: id, providerID: providerID) else { return .failure("network object not found") }
        return .success("\(entry.objectID.uuidString) \(entry.providerID) \(entry.objectType) \(entry.name)")
    }
}

/// The approval-gated `attach_workspace` PositronicKit tool.
public struct AttachWorkspaceTool: Tool, Sendable {
    private let service: DiscoveredWorkspaceAttachmentService
    init(service: DiscoveredWorkspaceAttachmentService) { self.service = service }
    public let callName = "attach_workspace"
    public let name = "Attach workspace"
    public let description = "Imports and attaches an unambiguous discovered workspace to a timeline."
    public let requiresPermission = true
    public let sideEffects: ToolSideEffects = .mutating
    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "workspaceId") {
                JSONString().description("UUID of the discovered Workspace to attach.")
            }.required()
            JSONProperty(key: "timelineId") {
                JSONString().description("UUID of the Timeline that will own the attachment.")
            }.required()
        }.schemaDefinition
    }
    public func canExecute() async -> Bool { true }
    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard let workspaceRaw = parameters["workspaceId"]?.value as? String,
              let timelineRaw = parameters["timelineId"]?.value as? String,
              let workspaceID = UUID(uuidString: workspaceRaw), let timelineID = UUID(uuidString: timelineRaw) else {
            return .failure("workspaceId and timelineId must be UUID strings")
        }
        let workspace = try await service.attach(workspaceID: workspaceID, to: timelineID, approved: true)
        return .success(workspace.id.uuidString)
    }
}
