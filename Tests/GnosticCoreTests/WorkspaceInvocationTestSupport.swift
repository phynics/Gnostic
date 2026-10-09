// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore

/// A local capability used by provider and broker fixtures. Dispatch remains
/// in the production MultiplexedWorkspaceProvider.
@MainActor
final class WorkspaceInvocationTestWorkspace: LocalWorkspace {
    let reference: BackendWorkspaceReference
    var tools: [BackendWorkspaceTool]
    var beforeListing: (@MainActor @Sendable () async throws -> Void)?
    private(set) var invocationCount = 0
    private let execute: @Sendable (String, [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult

    init(
        id: UUID,
        tools: [GnosticWorkspaceToolDefinition],
        execute: @escaping @Sendable (String, [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult = { _, _ in .success("ok") }
    ) {
        let definitions = tools.map {
            BackendWorkspaceTool(
                id: $0.id, name: $0.name, description: $0.description,
                parametersSchema: .object($0.parametersSchema), requiresPermission: $0.requiresPermission
            )
        }
        reference = BackendWorkspaceReference(id: id, uri: "workspace://fixture", status: .available, tools: definitions)
        self.tools = definitions
        self.execute = execute
    }

    func listTools() async throws -> [BackendWorkspaceTool] {
        try await beforeListing?()
        return tools
    }

    func executeTool(id: String, parameters: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult {
        invocationCount += 1
        return try await execute(id, parameters)
    }
}

@MainActor
func makeWorkspaceInvocationProvider(
    workspaceID: UUID,
    tools: [GnosticWorkspaceToolDefinition],
    execute: @escaping @Sendable (String, [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult
) -> MultiplexedWorkspaceProvider {
    let workspace = WorkspaceInvocationTestWorkspace(id: workspaceID, tools: tools, execute: execute)
    return MultiplexedWorkspaceProvider(workspaces: [workspaceID: workspace], workspaceStatus: { _ in .available })
}
