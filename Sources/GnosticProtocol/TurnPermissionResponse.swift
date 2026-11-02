// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public struct TurnPermissionResponse: Codable, Sendable {
    public let protocolMajor: Int
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let approved: Bool
    public let targetProviderID: String?
    /// Why the client made no decision. When set, the request resolves as
    /// unavailable, never as a denial, and `approved` must be `false`.
    public let unavailableReason: String?

    public init(correlationID: String, timelineID: UUID, clientTurnID: String, approved: Bool, targetProviderID: String? = nil, unavailableReason: String? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.approved = approved
        self.targetProviderID = targetProviderID
        self.unavailableReason = unavailableReason
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, correlationID, timelineID, clientTurnID, approved, targetProviderID, unavailableReason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        correlationID = try container.decode(String.self, forKey: .correlationID)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        approved = try container.decode(Bool.self, forKey: .approved)
        targetProviderID = try container.decodeIfPresent(String.self, forKey: .targetProviderID)
        unavailableReason = try container.decodeIfPresent(String.self, forKey: .unavailableReason)
    }

    public func targeted(to providerID: String?) -> Self {
        Self(
            correlationID: correlationID,
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            approved: approved,
            targetProviderID: providerID,
            unavailableReason: unavailableReason,
            protocolMajor: protocolMajor
        )
    }
}
