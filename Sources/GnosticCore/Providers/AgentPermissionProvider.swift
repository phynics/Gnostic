// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

public struct AscendantPermissionResponse: Codable, Sendable {
    public let protocolMajor: Int
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let approved: Bool
    public let targetProviderID: String?

    public init(correlationID: String, timelineID: UUID, clientTurnID: String, approved: Bool, targetProviderID: String? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.approved = approved
        self.targetProviderID = targetProviderID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, correlationID, timelineID, clientTurnID, approved, targetProviderID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        correlationID = try container.decode(String.self, forKey: .correlationID)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        approved = try container.decode(Bool.self, forKey: .approved)
        targetProviderID = try container.decodeIfPresent(String.self, forKey: .targetProviderID)
    }

    public func targeted(to providerID: String?) -> Self {
        Self(
            correlationID: correlationID,
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            approved: approved,
            targetProviderID: providerID,
            protocolMajor: protocolMajor
        )
    }
}

public struct AscendantPermissionProvider: Sendable {
    public static let responseOperation = "me.atkn.gnostic.ascendant.permission.respond"
    public static let responseChannel = "me.atkn.gnostic.ascendant.permission.response"

    private let coordinator: AscendantPermissionCoordinator

    public init(coordinator: AscendantPermissionCoordinator) {
        self.coordinator = coordinator
    }

    public func handle(parameters: String?) async throws -> CallHandlerResult {
        guard let parameters else {
            return .failure(code: GnosticProtocolError.missing.statusCode, message: GnosticProtocolError.missing.failureMessage)
        }
        let response: AscendantPermissionResponse
        do {
            response = try JSONDecoder().decode(AscendantPermissionResponse.self, from: Data(parameters.utf8))
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch {
            return .failure(code: 400, message: "Invalid Ascendant permission response")
        }
        guard !response.correlationID.isEmpty, !response.clientTurnID.isEmpty else {
            return .failure(code: 400, message: "Invalid Ascendant permission response")
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
        return .success(result: #"{"protocolMajor":2,"accepted":true}"#)
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.responseOperation, context: context) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }

    /// Observes one-way permission responses without competing with an active
    /// `ascendant.turn` Call/Return handler on the same communication manager.
    @MainActor
    public func observeResponses(on communication: CommunicationManager, providerID: String? = nil) async throws -> Task<Void, Never> {
        let stream = try await communication.observeChannelStream(channelId: Self.responseChannel)
        return Task { [coordinator] in
            for await snapshot in stream {
                guard let raw = snapshot.privateData,
                      let response = try? JSONDecoder().decode(
                          AscendantPermissionResponse.self,
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
    public static func responseEvent(_ response: AscendantPermissionResponse) throws -> ChannelEvent {
        let data = try JSONEncoder().encode(response)
        guard let privateData = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        let marker = CoatyObject(
            coreType: .CoatyObject,
            objectType: CoatyObject.objectType,
            objectId: CoatyUUID(),
            name: "Gnostic ascendant permission response"
        )
        return try ChannelEvent.with(
            object: marker,
            channelId: responseChannel,
            privateData: privateData
        )
    }
}
