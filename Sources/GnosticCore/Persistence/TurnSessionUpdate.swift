// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
import GnosticProtocol

/// An incremental or terminal update that the Timeline journal records for a Turn.
///
/// This type lives in `GnosticCore`, outside the stable products, because the
/// journaled `update` is an ACP wire value. The encoding is the journal format.
/// `update` is the text of the frame the Runtime sent (`ReceivedACPUpdate`), so
/// the journal keeps what the Runtime sent and not a re-encoded value.
public struct TurnSessionUpdate: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let sequence: Int
    public let receivedUpdate: ReceivedACPUpdate
    public let terminal: Bool
    public let terminalOutcome: TurnTerminalOutcome?

    /// The typed projection of the update, or `nil` when the received update has none.
    public var update: ACPSessionUpdate? { receivedUpdate.update }

    public init(
        timelineID: UUID,
        clientTurnID: String,
        sequence: Int,
        update: ACPSessionUpdate,
        terminal: Bool = false,
        terminalOutcome: TurnTerminalOutcome? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.init(
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            sequence: sequence,
            receivedUpdate: ReceivedACPUpdate(update),
            terminal: terminal,
            terminalOutcome: terminalOutcome,
            protocolMajor: protocolMajor
        )
    }

    public init(
        timelineID: UUID,
        clientTurnID: String,
        sequence: Int,
        receivedUpdate: ReceivedACPUpdate,
        terminal: Bool = false,
        terminalOutcome: TurnTerminalOutcome? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.sequence = sequence
        self.receivedUpdate = receivedUpdate
        self.terminal = terminal
        self.terminalOutcome = terminalOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, clientTurnID, sequence, update, terminal, terminalOutcome
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encode(clientTurnID, forKey: .clientTurnID)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(receivedUpdate, forKey: .update)
        try container.encode(terminal, forKey: .terminal)
        try container.encodeIfPresent(terminalOutcome, forKey: .terminalOutcome)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        sequence = try container.decode(Int.self, forKey: .sequence)
        receivedUpdate = try container.decode(ReceivedACPUpdate.self, forKey: .update)
        terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        terminalOutcome = try container.decodeIfPresent(TurnTerminalOutcome.self, forKey: .terminalOutcome)
    }
}
