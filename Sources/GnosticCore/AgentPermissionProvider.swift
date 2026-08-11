// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

public struct AgentPermissionResponse: Codable, Sendable {
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let approved: Bool

    public init(correlationID: String, timelineID: UUID, clientTurnID: String, approved: Bool) {
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.approved = approved
    }
}

public struct AgentPermissionProvider: Sendable {
    public static let responseOperation = "me.atkn.gnostic.agent.permission.respond"

    private let coordinator: AscendantPermissionCoordinator

    public init(coordinator: AscendantPermissionCoordinator) {
        self.coordinator = coordinator
    }

    public func handle(parameters: String?) async throws -> CallHandlerResult {
        guard let parameters,
              let response = try? JSONDecoder().decode(
                  AgentPermissionResponse.self,
                  from: Data(parameters.utf8)
              ),
              !response.correlationID.isEmpty,
              !response.clientTurnID.isEmpty else {
            return .failure(code: 400, message: "Invalid agent permission response")
        }
        let accepted = await coordinator.respond(
            correlationID: response.correlationID,
            timelineID: response.timelineID,
            clientTurnID: response.clientTurnID,
            approved: response.approved
        )
        guard accepted else {
            return .failure(code: 409, message: "Permission correlation is stale or mismatched")
        }
        return .success(result: #"{"accepted":true}"#)
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.responseOperation) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }
}
