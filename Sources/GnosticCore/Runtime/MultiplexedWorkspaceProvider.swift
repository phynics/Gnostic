// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

/// One unary Axoloty handler serving every local Workspace by workspace ID.
///
/// This is transport infrastructure: its registration and cancellation belong
/// to ``NodeTransport`` rather than the node composition root.
public actor MultiplexedWorkspaceProvider {
    public static let invocationOperation = WorkspaceProvider.invocationOperation

    private let workspaces: [UUID: any Workspace]
    private let isAvailable: @Sendable () async -> Bool

    public init(
        workspaces: [UUID: any Workspace],
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.workspaces = workspaces
        self.isAvailable = isAvailable
    }

    public func handle(parameters: String?, expectedProviderID: String? = nil) async throws -> CallHandlerResult {
        guard await isAvailable() else { throw NodeRuntimeError.notRunning }
        do {
            try GnosticProtocol.validatePayload(parameters)
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        }
        guard let parameters else { throw WorkspaceError.toolExecutionNotSupported }
        let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
        if let expectedProviderID, let providerID = invocation.providerID,
           providerID.lowercased() != expectedProviderID.lowercased() {
            throw WorkspaceError.connectionFailed
        }
        guard let workspace = workspaces[invocation.workspaceID] else {
            throw WorkspaceError.workspaceNotFound
        }
        let result = try await workspace.executeTool(id: invocation.toolID, parameters: invocation.arguments)
        let data = try JSONEncoder().encode(result)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["protocolMajor"] = GnosticProtocol.currentMajor
        return .success(result: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        let providerID = communication.identity.objectId.string
        return try await communication.registerCallHandler(operation: Self.invocationOperation, context: communication.identity) { [self] request in
            try await handle(parameters: request.parameters, expectedProviderID: providerID)
        }
    }
}
