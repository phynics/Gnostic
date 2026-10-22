// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation

/// Terminal state classification of a completed Timeline Turn.
public enum TimelineTurnTerminalOutcome: String, Codable, Sendable, Equatable {
    case completed
    case endedUnspecified
    case cancelled
    case failed
    case insertionUnknown
    case unavailable

    public static func from(stopReason: ACPStopReason?) -> TimelineTurnTerminalOutcome {
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

/// Lifecycle progression of an envelope through insertion and execution.
public enum TimelineTurnLifecycleState: String, Codable, Sendable, Equatable {
    case pendingInsertion
    case inserted
    case insertionUnknown
    case active
    case completed
    case cancelled
    case failed
}

/// Timeline-owned envelope for an ACP Turn.
public struct TimelineTurnEnvelope: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let sessionID: UUID
    public let runtimeID: UUID
    public let clientTurnID: String
    public let admissionDigest: String
    public let sequence: Int
    public let acpVersionTag: String
    public let prompt: [ACPContentBlock]
    public var state: TimelineTurnLifecycleState
    public var messageID: String?
    public var terminalOutcome: TimelineTurnTerminalOutcome?

    public init(
        timelineID: UUID,
        sessionID: UUID,
        runtimeID: UUID,
        clientTurnID: String,
        admissionDigest: String,
        sequence: Int = 1,
        acpVersionTag: String,
        prompt: [ACPContentBlock],
        state: TimelineTurnLifecycleState = .pendingInsertion,
        messageID: String? = nil,
        terminalOutcome: TimelineTurnTerminalOutcome? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.sessionID = sessionID
        self.runtimeID = runtimeID
        self.clientTurnID = clientTurnID
        self.admissionDigest = admissionDigest
        self.sequence = sequence
        self.acpVersionTag = acpVersionTag
        self.prompt = prompt
        self.state = state
        self.messageID = messageID
        self.terminalOutcome = terminalOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, sessionID, runtimeID, clientTurnID
        case admissionDigest, sequence, acpVersionTag, prompt, state, messageID, terminalOutcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        runtimeID = try container.decode(UUID.self, forKey: .runtimeID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        admissionDigest = try container.decode(String.self, forKey: .admissionDigest)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 1
        acpVersionTag = try container.decode(String.self, forKey: .acpVersionTag)
        prompt = try container.decode([ACPContentBlock].self, forKey: .prompt)
        state = try container.decode(TimelineTurnLifecycleState.self, forKey: .state)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        terminalOutcome = try container.decodeIfPresent(TimelineTurnTerminalOutcome.self, forKey: .terminalOutcome)
    }

    /// Computes a canonical SHA-256 admission digest for the given prompt and version tag.
    public static func computeAdmissionDigest(prompt: [ACPContentBlock], acpVersionTag: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(prompt) else {
            return SHA256.hexDigest(acpVersionTag)
        }
        var combined = data
        combined.append(0x0a) // newline separator
        combined.append(Data(acpVersionTag.utf8))
        return SHA256.hexDigest(Array(combined))
    }
}

/// An incremental or terminal update streamed during a Timeline Turn.
public struct TimelineTurnUpdate: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let sequence: Int
    public let update: ACPSessionUpdate
    public let terminal: Bool
    public let terminalOutcome: TimelineTurnTerminalOutcome?

    public init(
        timelineID: UUID,
        clientTurnID: String,
        sequence: Int,
        update: ACPSessionUpdate,
        terminal: Bool = false,
        terminalOutcome: TimelineTurnTerminalOutcome? = nil,
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
        terminalOutcome = try container.decodeIfPresent(TimelineTurnTerminalOutcome.self, forKey: .terminalOutcome)
    }
}

/// The result returned upon completion of a Timeline Turn.
public struct TimelineTurnResult: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let sequence: Int
    public let terminalOutcome: TimelineTurnTerminalOutcome
    public let replayed: Bool
    public let messageID: String?

    public init(
        timelineID: UUID,
        clientTurnID: String,
        sequence: Int = 1,
        terminalOutcome: TimelineTurnTerminalOutcome,
        replayed: Bool = false,
        messageID: String? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.sequence = sequence
        self.terminalOutcome = terminalOutcome
        self.replayed = replayed
        self.messageID = messageID
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, clientTurnID, sequence, terminalOutcome, replayed, messageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 1
        terminalOutcome = try container.decode(TimelineTurnTerminalOutcome.self, forKey: .terminalOutcome)
        replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
    }
}

/// A request to cancel an in-flight Timeline Turn.
public struct TimelineTurnCancellationRequest: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String

    public init(
        timelineID: UUID,
        clientTurnID: String,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, clientTurnID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
    }
}

/// The result of a Timeline Turn cancellation request.
public struct TimelineTurnCancellationResult: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let cancelled: Bool

    public init(
        timelineID: UUID,
        clientTurnID: String,
        cancelled: Bool,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.cancelled = cancelled
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, clientTurnID, cancelled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        cancelled = try container.decode(Bool.self, forKey: .cancelled)
    }
}

/// A request to replay recorded updates for a Timeline Turn.
public struct TimelineTurnReplayRequest: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String

    public init(
        timelineID: UUID,
        clientTurnID: String,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, clientTurnID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
    }
}

/// Recorded replay updates for a Timeline Turn.
public struct TimelineTurnReplay: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let updates: [TimelineTurnUpdate]
    public let terminalOutcome: TimelineTurnTerminalOutcome?

    public init(
        timelineID: UUID,
        clientTurnID: String,
        updates: [TimelineTurnUpdate],
        terminalOutcome: TimelineTurnTerminalOutcome? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.updates = updates
        self.terminalOutcome = terminalOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, clientTurnID, updates, terminalOutcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        updates = try container.decode([TimelineTurnUpdate].self, forKey: .updates)
        terminalOutcome = try container.decodeIfPresent(TimelineTurnTerminalOutcome.self, forKey: .terminalOutcome)
    }
}

/// A host-mediated permission request crossing Node boundaries.
public struct TimelinePermissionRequest: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let title: String
    public let subject: String?
    public let options: [ACPPermissionOption]

    public init(
        correlationID: String,
        timelineID: UUID,
        clientTurnID: String,
        title: String,
        subject: String? = nil,
        options: [ACPPermissionOption] = [],
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.title = title
        self.subject = subject
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, correlationID, timelineID, clientTurnID, title, subject, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        correlationID = try container.decode(String.self, forKey: .correlationID)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        title = try container.decode(String.self, forKey: .title)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        options = try container.decodeIfPresent([ACPPermissionOption].self, forKey: .options) ?? []
    }
}

/// The response to a host-mediated permission request.
public struct TimelinePermissionResponse: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let approved: Bool
    public let decision: String?

    public init(
        correlationID: String,
        timelineID: UUID,
        clientTurnID: String,
        approved: Bool,
        decision: String? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.approved = approved
        self.decision = decision
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, correlationID, timelineID, clientTurnID, approved, decision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        correlationID = try container.decode(String.self, forKey: .correlationID)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
        approved = try container.decode(Bool.self, forKey: .approved)
        decision = try container.decodeIfPresent(String.self, forKey: .decision)
    }
}

/// The result of processing a host-mediated permission response.
public struct TimelinePermissionMutationResult: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let correlationID: String
    public let accepted: Bool

    public init(
        correlationID: String,
        accepted: Bool,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.correlationID = correlationID
        self.accepted = accepted
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, correlationID, accepted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        correlationID = try container.decode(String.self, forKey: .correlationID)
        accepted = try container.decode(Bool.self, forKey: .accepted)
    }
}
