// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// A local capability used by provider and broker fixtures. Dispatch remains
/// in the production MultiplexedWorkspaceProvider.
///
/// This target is test-only support shared by `GnosticCoreTests` and
/// `GnosticClientTests`, so its surface is public to those test targets.
@MainActor
public final class WorkspaceInvocationTestWorkspace: LocalWorkspace, LocalWorkspaceHealth {
    public let reference: BackendWorkspaceReference
    public var tools: [BackendWorkspaceTool]
    public var isHealthy = true
    public var beforeListing: (@MainActor @Sendable () async throws -> Void)?
    public private(set) var invocationCount = 0
    private let execute: @Sendable (String, [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult

    public init(
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

    public func listTools() async throws -> [BackendWorkspaceTool] {
        try await beforeListing?()
        return tools
    }

    public func executeTool(id: String, parameters: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult {
        invocationCount += 1
        return try await execute(id, parameters)
    }
}
