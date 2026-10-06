// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

/// The durable events that make up one identified Turn's lifecycle.
public enum TurnEventKind: Codable, Sendable, Equatable {
    /// A Turn began. The digest identifies the prompt without persisting it.
    case started(messageDigest: UInt64?)
    /// One bounded update was emitted.
    case update(AscendantTurnUpdate)
    /// The Turn's retention slot was released.
    case finished
}

/// One durable record in the Turn event journal.
///
/// The journal never stores prompt text or tool arguments beyond the bounded
/// update payload that already crosses the wire. ``TurnEventKind/started``
/// carries only the prompt digest, so a restart can still detect a conflicting
/// replay without putting conversation content at rest.
public struct TurnEventRecord: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let event: TurnEventKind

    public init(
        protocolMajor: Int = GnosticProtocol.currentMajor,
        timelineID: UUID,
        clientTurnID: String,
        event: TurnEventKind
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.event = event
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID, event }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encode(try GnosticWirePayload.canonicalClientTurnID(clientTurnID), forKey: .clientTurnID)
        try container.encode(event, forKey: .event)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try GnosticWirePayload.canonicalClientTurnID(
            container.decode(String.self, forKey: .clientTurnID)
        )
        event = try container.decode(TurnEventKind.self, forKey: .event)
    }
}
