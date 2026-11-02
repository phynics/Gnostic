// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

public struct AscendantPermissionProvider: Sendable {
    public static let responseOperation = "me.atkn.gnostic.permission.respond"
    public static let responseChannel = "me.atkn.gnostic.permission.response"

    private let coordinator: AscendantPermissionCoordinator

    public init(coordinator: AscendantPermissionCoordinator) {
        self.coordinator = coordinator
    }

    public func handle(parameters: String?) async throws -> CallHandlerResult {
        guard let parameters else {
            return .failure(GnosticProtocolError.missing)
        }
        let response: TurnPermissionResponse
        do {
            response = try JSONDecoder().decode(TurnPermissionResponse.self, from: Data(parameters.utf8))
        } catch let error as GnosticProtocolError {
            return .failure(error)
        } catch {
            return .failure(code: 400, reasonCode: "invalidPermissionResponse", message: "Invalid Ascendant permission response")
        }
        guard !response.correlationID.isEmpty, !response.clientTurnID.isEmpty else {
            return .failure(code: 400, reasonCode: "invalidPermissionResponse", message: "Invalid Ascendant permission response")
        }
        let accepted = await coordinator.respond(
            correlationID: response.correlationID,
            timelineID: response.timelineID,
            clientTurnID: response.clientTurnID,
            approved: response.approved,
            unavailableReason: response.unavailableReason
        )
        guard accepted else {
            return .failure(code: 409, reasonCode: "permissionCorrelationStale", message: "Permission correlation is stale or mismatched")
        }
        return .success(result: "{\"protocolMajor\":\(GnosticProtocol.currentMajor),\"accepted\":true}")
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.responseOperation, context: context) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }

    /// Observes one-way permission responses without competing with an active
    /// `turn` Call/Return handler on the same communication manager.
    @MainActor
    public func observeResponses(on communication: CommunicationManager, providerID: String? = nil) async throws -> Task<Void, Never> {
        let stream = try await communication.observeChannelStream(channelId: Self.responseChannel)
        return Task { [coordinator] in
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                guard let raw = snapshot.privateData,
                      let response = try? JSONDecoder().decode(
                          TurnPermissionResponse.self,
                          from: Data(raw.utf8)
                      ) else { continue }
                if let target = response.targetProviderID,
                   let providerID,
                   target.lowercased() != providerID.lowercased() { continue }
                guard !Task.isCancelled else { break }
                _ = await coordinator.respond(
                    correlationID: response.correlationID,
                    timelineID: response.timelineID,
                    clientTurnID: response.clientTurnID,
                    approved: response.approved,
                    unavailableReason: response.unavailableReason
                )
            }
        }
    }

    /// Creates a generic Axoloty Channel event carrying one permission decision.
    public static func responseEvent(_ response: TurnPermissionResponse) throws -> ChannelEvent {
        let data = try GnosticWirePayload.encode(response, context: "permission.response event")
        guard let privateData = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        let marker = CoatyObject(
            coreType: .coatyObject,
            objectType: CoatyObject.objectType,
            objectId: CoatyUUID(),
            name: "Gnostic permission response"
        )
        return try ChannelEvent.with(
            object: marker,
            channelId: responseChannel,
            privateData: privateData
        )
    }
}
