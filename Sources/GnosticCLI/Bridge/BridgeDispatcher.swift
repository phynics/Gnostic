// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKShared
import PositronicKit

/// Domain dispatcher for the stable `gnostic.*` JSON-RPC surface.
@MainActor
public final class BridgeDispatcher: Sendable {
    private let client: GnosticRemoteClient

    public init(client: GnosticRemoteClient) {
        self.client = client
    }

    public func handle(_ request: JSONRPCRequest) async throws -> AnyCodable {
        switch request.method {
        case "gnostic.ascendant.list":
            return try await ascendants()
        case "gnostic.ascendant.chat":
            let input: ChatInput = try decode(request.params)
            guard let timelineID = UUID(uuidString: input.timelineID) else {
                throw BridgeMethodError.invalidParams("timelineID must be a UUID")
            }
            return try await any(client.chat(message: input.message, timelineID: timelineID))
        case "gnostic.timeline.list":
            return try await any(client.listTimelines())
        case "gnostic.timeline.status":
            let input: TimelineIDInput = try decode(request.params)
            guard let timelineID = UUID(uuidString: input.timelineID) else {
                throw BridgeMethodError.invalidParams("timelineID must be a UUID")
            }
            return try await any(client.timelineStatus(timelineID: timelineID))
        case "gnostic.timeline.create":
            let input: TimelineCreateInput = try decode(request.params)
            guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeMethodError.invalidParams("title must not be empty")
            }
            return try await any(client.createTimeline(title: input.title))
        case "gnostic.timeline.update":
            let input: TimelineUpdateInput = try decode(request.params)
            guard let timelineID = UUID(uuidString: input.timelineID) else {
                throw BridgeMethodError.invalidParams("timelineID must be a UUID")
            }
            return try await any(client.updateTimeline(timelineID: timelineID, title: input.title))
        case "gnostic.workspace.list":
            return try await workspaces()
        case "gnostic.workspace.attach", "gnostic.workspace.detach":
            let input: WorkspaceMutationInput = try decode(request.params)
            guard let workspaceID = UUID(uuidString: input.workspaceID),
                  let timelineID = UUID(uuidString: input.timelineID) else {
                throw BridgeMethodError.invalidParams("workspaceID and timelineID must be UUIDs")
            }
            let result = request.method.hasSuffix("attach")
                ? try await client.attach(workspaceID: workspaceID, timelineID: timelineID)
                : try await client.detach(workspaceID: workspaceID, timelineID: timelineID)
            return .boolean(result)
        case "gnostic.workspace.invoke":
            let input: WorkspaceInvokeInput = try decode(request.params)
            guard let workspaceID = UUID(uuidString: input.workspaceID),
                  let timelineID = UUID(uuidString: input.timelineID) else {
                throw BridgeMethodError.invalidParams("workspaceID and timelineID must be UUIDs")
            }
            let result = try await client.invokeWorkspace(
                workspaceID: workspaceID,
                providerID: input.providerID,
                timelineID: timelineID,
                toolID: input.toolID,
                parameters: input.arguments,
                approved: input.approved
            )
            return try any(result)
        default:
            throw BridgeMethodError.methodNotFound(request.method)
        }
    }

    private func ascendants() async throws -> AnyCodable {
        let entries = await client.listNetworkObjects().filter { $0.objectType == GnosticObjectType.agent }
        return try any(entries.map { entry in
            AscendantSummary(
                id: entry.objectID,
                providerID: entry.providerID,
                name: entry.name,
                properties: entry.knownProperties
            )
        })
    }

    private func workspaces() async throws -> AnyCodable {
        let timelines = try await client.listTimelines()
        let entries = await client.listNetworkObjects().filter { $0.objectType == GnosticObjectType.workspace }
        return try any(entries.compactMap { entry -> WorkspaceSummary? in
            guard let descriptor = entry.workspace else { return nil }
            let attached = timelines.filter { $0.attachedWorkspaceIDs.contains(descriptor.id) }.map(\.timelineID)
            return WorkspaceSummary(
                id: descriptor.id,
                providerID: entry.providerID,
                name: entry.name,
                uri: descriptor.uri,
                isAvailable: descriptor.isAvailable,
                attachedTimelineIDs: attached,
                tools: descriptor.tools.map(ToolSummary.init)
            )
        })
    }

    private func decode<T: Decodable>(_ params: AnyCodable?) throws -> T {
        guard let params,
              let data = try? JSONEncoder().encode(params),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw BridgeMethodError.invalidParams("invalid method parameters")
        }
        return value
    }

    private func any<T: Encodable>(_ value: T) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(value))
    }
}

private struct ChatInput: Codable, Sendable {
    let message: String
    let timelineID: String
}

private struct TimelineIDInput: Codable, Sendable { let timelineID: String }
private struct TimelineCreateInput: Codable, Sendable { let title: String }
private struct TimelineUpdateInput: Codable, Sendable { let timelineID: String; let title: String }
private struct WorkspaceMutationInput: Codable, Sendable { let workspaceID: String; let timelineID: String }

private struct WorkspaceInvokeInput: Codable, Sendable {
    let workspaceID: String
    let providerID: String
    let timelineID: String
    let toolID: String
    let arguments: [String: AnyCodable]
    let approved: Bool
}

private struct AscendantSummary: Codable, Sendable {
    let id: UUID
    let providerID: String
    let name: String
    let properties: [String: NetworkDynamicValue]
}

private struct ToolSummary: Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let parametersSchema: [String: AnyCodable]
    let usageExample: String?
    let requiresPermission: Bool

    init(_ tool: GnosticWorkspaceTool) {
        id = tool.id
        name = tool.name
        description = tool.toolDescription
        parametersSchema = tool.parametersSchema
        usageExample = tool.usageExample
        requiresPermission = tool.requiresPermission
    }
}

private struct WorkspaceSummary: Codable, Sendable {
    let id: UUID
    let providerID: String
    let name: String
    let uri: String
    let isAvailable: Bool
    let attachedTimelineIDs: [UUID]
    let tools: [ToolSummary]
}
