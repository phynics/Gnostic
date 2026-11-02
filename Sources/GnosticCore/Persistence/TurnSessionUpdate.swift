// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
import GnosticProtocol

/// An incremental or terminal update that the Timeline journal records for a Turn.
///
/// This type lives in `GnosticCore`, outside the stable products, because the
/// journaled `update` is an ACP wire value. The encoding is the journal format
/// and does not change.
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
