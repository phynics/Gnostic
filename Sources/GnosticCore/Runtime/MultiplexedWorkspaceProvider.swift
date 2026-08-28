// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// One unary Axoloty handler serving every local Workspace by workspace ID.
///
/// This is transport infrastructure: its registration and cancellation belong
/// to ``NodeTransport`` rather than the node composition root.
public actor MultiplexedWorkspaceProvider {
    public static let invocationOperation = GnosticWorkspaceProvider.invocationOperation

    private let workspaces: [UUID: any WorkspaceProvider]
    private let isAvailable: @Sendable () async -> Bool

    public init(
        workspaces: [UUID: any WorkspaceProvider],
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.workspaces = workspaces
        self.isAvailable = isAvailable
    }

    public func handle(parameters: String?, expectedProviderID: String? = nil) async throws -> CallHandlerResult {
        do {
            guard await isAvailable() else { throw NodeRuntimeError.notRunning }
            try GnosticProtocol.validatePayload(parameters)
            guard let parameters else { throw WorkspaceError.toolExecutionNotSupported }
            let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
            if let expectedProviderID, let providerID = invocation.providerID,
               providerID.lowercased() != expectedProviderID.lowercased() {
                throw WorkspaceError.connectionFailed
            }
            guard let workspace = workspaces[invocation.workspaceID] else {
                throw WorkspaceError.workspaceNotFound
            }
            guard let workspace = workspace as? any WorkspaceToolProvider else {
                throw WorkspaceError.toolExecutionNotSupported
            }
            let result = try await workspace.executeTool(id: invocation.toolID, parameters: invocation.arguments)
            let data = try JSONEncoder().encode(result)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderInvalidValue)
            }
            object["protocolMajor"] = GnosticProtocol.currentMajor
            return .success(result: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch let error as NodeRuntimeError {
            return failure(code: error.statusCode, reasonCode: error.reasonCode, message: error.localizedDescription)
        } catch let error as DecodingError {
            return failure(code: 400, reasonCode: "invalidWorkspaceInvocationPayload", message: String(describing: error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failure(code: 500, reasonCode: "workspaceInvocationFailed", message: String(describing: error))
        }
    }

    private func failure(code: Int, reasonCode: String, message: String) -> CallHandlerResult {
        .failure(code: code, message: GnosticProtocol.failureMessage(reasonCode: reasonCode, message: message))
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        let providerID = communication.identity.objectId.string
        return try await communication.registerCallHandler(operation: Self.invocationOperation, context: communication.identity) { [self] request in
            try await handle(parameters: request.parameters, expectedProviderID: providerID)
        }
    }
}
