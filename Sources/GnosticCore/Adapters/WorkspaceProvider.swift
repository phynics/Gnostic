// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

/// The wire payload for Gnostic's generic remote workspace invocation.
public struct WorkspaceInvocation: Codable, Sendable {
    /// The stable identifier of the advertised workspace.
    public let workspaceID: UUID

    /// The catalog provider identity selected for this invocation.
    public let providerID: String?

    /// The advertised custom tool identifier.
    public let toolID: String

    /// The tool arguments supplied by the caller.
    public let arguments: [String: AnyCodable]

    /// Creates an invocation payload.
    public init(workspaceID: UUID, providerID: String? = nil, toolID: String, arguments: [String: AnyCodable]) {
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.toolID = toolID
        self.arguments = arguments
    }
}

/// Hosts arbitrary custom workspace tools over Gnostic's unary Call/Return operation.
public actor WorkspaceProvider {
    /// The single operation used for all workspace tool invocations.
    public static let invocationOperation = "me.atkn.gnostic.workspace.invoke"

    /// Executes one advertised tool.
    public typealias ToolExecutor = @Sendable (_ toolID: String, _ arguments: [String: AnyCodable]) async throws -> ToolResult

    private let workspaceID: UUID
    private let definitions: [String: WorkspaceToolDefinition]
    private let executor: ToolExecutor

    /// Creates a provider for a workspace's advertised custom tools.
    public init(workspaceID: UUID, tools: [WorkspaceToolDefinition], execute: @escaping ToolExecutor) {
        self.workspaceID = workspaceID
        definitions = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        executor = execute
    }

    /// Returns the exact custom tools currently advertised by this provider.
    public func listTools() -> [ToolReference] {
        definitions.values.sorted { $0.id < $1.id }.map(ToolReference.custom)
    }

    /// Dispatches a decoded invocation only when it addresses this workspace and an advertised tool.
    public func invoke(_ invocation: WorkspaceInvocation) async throws -> ToolResult {
        guard invocation.workspaceID == workspaceID else { throw WorkspaceError.workspaceNotFound }
        guard definitions[invocation.toolID] != nil else { throw WorkspaceError.toolExecutionNotSupported }
        return try await executor(invocation.toolID, invocation.arguments)
    }

    /// Decodes a generic Call payload and returns the serialized PositronicKit tool result.
    public func handle(parameters: String?) async throws -> CallHandlerResult {
        guard let parameters else { throw WorkspaceError.toolExecutionNotSupported }
        let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
        let result = try await invoke(invocation)
        let encoded = try JSONEncoder().encode(result)
        return .success(result: String(decoding: encoded, as: UTF8.self))
    }

    /// Registers this provider with Axoloty's released unary Call handler.
    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.invocationOperation, context: communication.identity) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }
}
