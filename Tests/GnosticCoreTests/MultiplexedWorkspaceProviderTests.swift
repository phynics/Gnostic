// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import Testing

@Suite("Production Workspace invocation and query")
@MainActor
struct MultiplexedWorkspaceProviderTests {
    private let definition = GnosticWorkspaceToolDefinition(
        id: "allowed", name: "Allowed tool", description: "An advertised tool.",
        parametersSchema: ["type": .string("object")], requiresPermission: true
    )

    @Test("registry status blocks remote execution and recovery permits it", arguments: [
        NodeRegistry.WorkspaceEffectiveStatus.unavailable, .unsupported,
    ])
    func rejectsUnavailableWorkspace(status: NodeRegistry.WorkspaceEffectiveStatus) async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = provider(for: workspace, registry: registry)
        #expect(await registry.setWorkspaceStatus(id: workspace.reference.id, status: status))

        let rejected = try await provider.handle(parameters: payload(for: workspace))

        try expectFailure(rejected, code: 409, reason: "workspaceUnavailable")
        #expect(workspace.invocationCount == 0)
        #expect(await registry.setWorkspaceStatus(id: workspace.reference.id, status: .available))
        let accepted = try await provider.handle(parameters: payload(for: workspace))
        guard case .success = accepted else { Issue.record("available Workspace was rejected"); return }
        #expect(workspace.invocationCount == 1)
    }

    @Test("a missing registry record cannot authorize execution")
    func rejectsMissingStatus() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let emptyManifest = NodeManifest.empty(broker: .init(host: "127.0.0.1", port: 1883, namespace: "fixture"))
        let registry = try NodeRegistry(plan: emptyManifest.compileLaunchPlan(), operatedTimelines: [])
        let provider = provider(for: workspace, registry: registry)

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 409, reason: "workspaceUnavailable")
        #expect(workspace.invocationCount == 0)
    }

    @Test("an unadvertised tool is rejected without exposing its identifier")
    func rejectsUnadvertisedTool() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = provider(for: workspace, registry: registry)
        let forged = "private-unadvertised-tool"

        let response = try await provider.handle(parameters: payload(for: workspace, toolID: forged))

        let failure = try expectFailure(response, code: 403, reason: "workspaceToolNotAdvertised")
        #expect(!failure.message.contains(forged))
        #expect(workspace.invocationCount == 0)
    }

    @Test("invocation uses the current tool catalog rather than a cached reference")
    func rejectsRemovedTool() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = provider(for: workspace, registry: registry)
        workspace.tools = []

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 403, reason: "workspaceToolNotAdvertised")
        #expect(workspace.invocationCount == 0)
    }

    @Test("availability is checked again after tool enumeration suspends")
    func rejectsStatusChangeDuringListing() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let workspaceID = workspace.reference.id
        workspace.beforeListing = {
            _ = await registry.setWorkspaceStatus(id: workspaceID, status: .unavailable)
        }
        let provider = provider(for: workspace, registry: registry)

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 409, reason: "workspaceUnavailable")
        #expect(workspace.invocationCount == 0)
    }

    @Test("a stopped Node cannot dispatch a Workspace tool")
    func rejectsStoppedNode() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace], workspaceStatus: { _ in .available }, isAvailable: { false }
        )

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 503, reason: "notRunning")
        #expect(workspace.invocationCount == 0)
    }

    @Test("query defaults to the first sorted page and preserves the terminal answer")
    func queryPagination() async throws {
        let second = GnosticWorkspaceToolDefinition(id: "z-last", name: "Last", description: "Last tool.")
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [second, definition])
        let provider = provider(for: workspace, registry: try registry(for: workspace))

        let first = try #require(try await provider.queryObjects(query(workspaceID: workspace.reference.id)))
        #expect(first.map(\.toolID) == [definition.id])
        let tool = try #require(first.first)
        #expect(tool.page == 0)
        #expect(tool.toolName == definition.name)
        #expect(tool.toolDescription == definition.description)
        #expect(tool.parametersSchema == definition.parametersSchema)
        #expect(tool.requiresPermission == definition.requiresPermission)
        let next = try #require(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: 1)))
        #expect(next.map(\.toolID) == [second.id])
        let terminal = try #require(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: 2)))
        #expect(terminal.isEmpty)
        #expect(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: -1)) == nil)
        #expect(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: "invalid")) == nil)
        #expect(try await provider.queryObjects(query(workspaceID: UUID())) == nil)
        #expect(workspace.invocationCount == 0)
    }

    private func registry(for workspace: WorkspaceInvocationTestWorkspace) throws -> NodeRegistry {
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "fixture"), node: .init(id: UUID()),
            workspaces: [.init(id: workspace.reference.id, name: "Fixture", uri: workspace.reference.uri)]
        )
        return try NodeRegistry(plan: manifest.compileLaunchPlan(), operatedTimelines: [])
    }

    private func provider(for workspace: WorkspaceInvocationTestWorkspace, registry: NodeRegistry) -> MultiplexedWorkspaceProvider {
        MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace],
            workspaceStatus: { id in await registry.effectiveWorkspaceStatus(id: id) }
        )
    }

    private func payload(for workspace: WorkspaceInvocationTestWorkspace, toolID: String = "allowed") throws -> String {
        String(decoding: try JSONEncoder().encode(WorkspaceInvocation(workspaceID: workspace.reference.id, toolID: toolID)), as: UTF8.self)
    }

    private func query(workspaceID: UUID, page: Any? = nil) throws -> QueryEventSnapshot {
        var conditions: [[Any]] = [["workspaceID", [7, workspaceID.uuidString.lowercased()]]]
        if let page { conditions.append(["page", [7, page]]) }
        let filter = try JSONSerialization.data(withJSONObject: ["conditions": ["and": conditions]])
        return QueryEventSnapshot(objectTypes: [GnosticObjectType.workspaceTool], objectFilter: String(decoding: filter, as: UTF8.self))
    }

    @discardableResult
    private func expectFailure(_ response: CallHandlerResult, code: Int, reason: String) throws -> GnosticProtocolFailure {
        guard case let .failure(actualCode, encoded, _) = response else {
            Issue.record("expected a structured invocation failure")
            return GnosticProtocolFailure(reasonCode: "missing", message: "missing")
        }
        let failure = try JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(encoded.utf8))
        #expect(actualCode == code)
        #expect(failure.statusCode == code)
        #expect(failure.reasonCode == reason)
        #expect(failure.protocolMajor == GnosticProtocol.currentMajor)
        return failure
    }
}
