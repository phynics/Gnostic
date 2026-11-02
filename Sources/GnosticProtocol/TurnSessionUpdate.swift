// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation
import GnosticACPWire

/// Terminal state classification of a completed Timeline Turn.
public enum TurnTerminalOutcome: String, Codable, Sendable, Equatable {
    case completed
    case endedUnspecified
    case cancelled
    case failed
    case insertionUnknown
    case unavailable

    public static func from(stopReason: ACPStopReason?) -> TurnTerminalOutcome {
        guard let stopReason else { return .endedUnspecified }
        switch stopReason {
        case .endTurn, .maxTokens, .maxTurnRequests:
            return .completed
        case .cancelled:
            return .cancelled
        case .error, .refusal:
            return .failed
        case .other:
            return .endedUnspecified
        }
    }
}

/// An incremental or terminal update streamed during a Timeline Turn.
public struct TurnSessionUpdate: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let sequence: Int
    public let update: ACPSessionUpdate
    public let terminal: Bool
    public let terminalOutcome: TurnTerminalOutcome?

    public init(
        timelineID: UUID,
        clientTurnID: String,
        sequence: Int,
        update: ACPSessionUpdate,
        terminal: Bool = false,
        terminalOutcome: TurnTerminalOutcome? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.sequence = sequence
        self.update = update
        self.terminal = terminal
        self.terminalOutcome = terminalOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, clientTurnID, sequence, update, terminal, terminalOutcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        sequence = try container.decode(Int.self, forKey: .sequence)
        update = try container.decode(ACPSessionUpdate.self, forKey: .update)
        terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        terminalOutcome = try container.decodeIfPresent(TurnTerminalOutcome.self, forKey: .terminalOutcome)
    }
}
