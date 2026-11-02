// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The wire payload for a remote Turn.
public struct TurnRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let message: String
    public let timelineID: UUID
    public let clientTurnID: String?

    public init(message: String, timelineID: UUID, clientTurnID: String? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.message = message
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, message, timelineID, clientTurnID }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(try GnosticWirePayload.canonicalTurnMessage(message), forKey: .message)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encodeIfPresent(clientTurnID, forKey: .clientTurnID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        message = try GnosticWirePayload.canonicalTurnMessage(try container.decode(String.self, forKey: .message))
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decodeIfPresent(String.self, forKey: .clientTurnID).map {
            try GnosticWirePayload.canonicalClientTurnID($0)
        }
    }
}

/// The wire result of a remote Turn.
public struct TurnResult: Codable, Sendable {
    public let protocolMajor: Int
    public let clientTurnID: String?
    public let text: String
    public let replayed: Bool

    public init(clientTurnID: String? = nil, text: String, replayed: Bool = false, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.clientTurnID = clientTurnID
        self.text = GnosticWirePayload.prefix(text, maximumBytes: GnosticWirePayload.maximumTurnResultTextBytes)
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor
        case clientTurnID
        case text
        case replayed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        if let clientTurnID {
            try container.encode(try GnosticWirePayload.canonicalClientTurnID(clientTurnID), forKey: .clientTurnID)
        }
        try container.encode(text, forKey: .text)
        try container.encode(replayed, forKey: .replayed)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        clientTurnID = try container.decodeIfPresent(String.self, forKey: .clientTurnID).map {
            try GnosticWirePayload.canonicalClientTurnID($0)
        }
        text = GnosticWirePayload.prefix(
            try container.decode(String.self, forKey: .text),
            maximumBytes: GnosticWirePayload.maximumTurnResultTextBytes
        )
        replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}

public struct TurnReplayRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let message: String?
    public let afterSequence: Int

    public init(timelineID: UUID, clientTurnID: String, message: String? = nil, afterSequence: Int = 0, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.message = message
        self.afterSequence = afterSequence
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID, message, afterSequence }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encode(clientTurnID, forKey: .clientTurnID)
        if let message {
            try container.encode(
                try GnosticWirePayload.canonicalTurnMessage(message, context: "turn.replay message"),
                forKey: .message
            )
        }
        try container.encode(afterSequence, forKey: .afterSequence)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try GnosticWirePayload.canonicalClientTurnID(
            container.decode(String.self, forKey: .clientTurnID)
        )
        message = try container.decodeIfPresent(String.self, forKey: .message).map {
            try GnosticWirePayload.canonicalTurnMessage($0, context: "turn.replay message")
        }
        afterSequence = try container.decodeIfPresent(Int.self, forKey: .afterSequence) ?? 0
    }
}

/// Identifies the admitted Turn that an explicit client cancellation targets.
public struct TurnCancellationRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String

    public init(timelineID: UUID, clientTurnID: String, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try GnosticWirePayload.canonicalClientTurnID(
            container.decode(String.self, forKey: .clientTurnID)
        )
    }
}

public struct TurnCancellationResult: Codable, Sendable {
    public let protocolMajor: Int
    public let cancelled: Bool

    public init(cancelled: Bool, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.cancelled = cancelled
    }
}
