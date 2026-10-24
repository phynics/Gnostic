// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Routes a Workspace invocation to the Node that advertises its Workspace.
///
/// The owner remains authoritative: its registered handler rechecks Timeline
/// attachment, effective status, tool membership, and permission immediately
/// before invoking the local Workspace.
@MainActor
struct AxolotyNetworkWorkspaceInvoker: NetworkWorkspaceInvoking {
    private struct ToolResult: Decodable {
        let protocolMajor: Int
        let isSuccess: Bool
        let output: String
        let error: String?

        private enum CodingKeys: String, CodingKey { case protocolMajor, isSuccess, output, error }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
            isSuccess = try container.decode(Bool.self, forKey: .isSuccess)
            output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
            error = try container.decodeIfPresent(String.self, forKey: .error)
        }
    }

    private let catalog: NetworkCatalog
    private let communication: CommunicationManager
    private let timeout: Duration

    init(
        catalog: NetworkCatalog,
        communication: CommunicationManager,
        timeout: Duration = .seconds(5)
    ) {
        self.catalog = catalog
        self.communication = communication
        self.timeout = timeout
    }

    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult {
        guard case let .available(providerID, _) = await catalog.workspaceAttachmentStatus(id: invocation.workspaceID) else {
            throw WorkspaceServiceError.workspaceNotFound
        }

        let request = WorkspaceInvocation(
            timelineID: invocation.timelineID,
            permissionApproved: invocation.permissionApproved,
            workspaceID: invocation.workspaceID,
            providerID: providerID,
            toolID: invocation.toolID,
            arguments: invocation.arguments
        )
        let payload = try GnosticWirePayload.encode(request, context: "workspace.invoke request")
        let response = try await communication.call(
            operation: GnosticWorkspaceProtocol.invocationOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            context: .provider(providerID),
            timeout: timeout
        )
        guard response.sourceId?.caseInsensitiveCompare(providerID) == .orderedSame else {
            throw WorkspaceServiceError.connectionFailed
        }

        let data = Data(response.result.utf8)
        try GnosticWirePayload.validateEvent(data, context: "workspace.invoke response")
        let result = try JSONDecoder().decode(ToolResult.self, from: data)
        return BackendWorkspaceResult(
            value: result.isSuccess ? .string(result.output) : nil,
            message: result.isSuccess ? nil : result.error,
            isSuccess: result.isSuccess
        )
    }
}
