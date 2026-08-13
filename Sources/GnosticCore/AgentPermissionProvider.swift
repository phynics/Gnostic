// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

public struct AgentPermissionResponse: Codable, Sendable {
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let approved: Bool
    public let targetProviderID: String?

    public init(correlationID: String, timelineID: UUID, clientTurnID: String, approved: Bool, targetProviderID: String? = nil) {
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.approved = approved
        self.targetProviderID = targetProviderID
    }

    public func targeted(to providerID: String?) -> Self {
        Self(
            correlationID: correlationID,
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            approved: approved,
            targetProviderID: providerID
        )
    }
}

public struct AgentPermissionProvider: Sendable {
    public static let responseOperation = "me.atkn.gnostic.agent.permission.respond"
    public static let responseChannel = "me.atkn.gnostic.agent.permission.response"

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
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.responseOperation, context: context) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }

    /// Observes one-way permission responses without competing with an active
    /// `agent.chat` Call/Return handler on the same communication manager.
    @MainActor
    public func observeResponses(on communication: CommunicationManager, providerID: String? = nil) async throws -> Task<Void, Never> {
        let stream = try await communication.observeChannelStream(channelId: Self.responseChannel)
        return Task { [coordinator] in
            for await snapshot in stream {
                guard let raw = snapshot.privateData,
                      let response = try? JSONDecoder().decode(
                          AgentPermissionResponse.self,
                          from: Data(raw.utf8)
                      ) else { continue }
                if let target = response.targetProviderID,
                   let providerID,
                   target.lowercased() != providerID.lowercased() { continue }
                _ = await coordinator.respond(
                    correlationID: response.correlationID,
                    timelineID: response.timelineID,
                    clientTurnID: response.clientTurnID,
                    approved: response.approved
                )
            }
        }
    }

    /// Creates a generic Axoloty Channel event carrying one permission decision.
    public static func responseEvent(_ response: AgentPermissionResponse) throws -> ChannelEvent {
        let data = try JSONEncoder().encode(response)
        guard let privateData = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        let marker = CoatyObject(
            coreType: .CoatyObject,
            objectType: CoatyObject.objectType,
            objectId: CoatyUUID(),
            name: "Gnostic agent permission response"
        )
        return try ChannelEvent.with(
            object: marker,
            channelId: responseChannel,
            privateData: privateData
        )
    }
}
