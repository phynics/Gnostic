// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The declared vocabulary of ``AscendantTurnUpdate/kind`` values.
///
/// The wire representation stays a `String` so that a peer emitting a kind
/// from a newer build decodes without loss. Use ``AscendantTurnUpdate/updateKind``
/// to read a kind that this build understands.
public enum AscendantTurnUpdateKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Incremental assistant output produced while a Turn runs.
    case assistantText = "assistant_text"
    /// Assistant output accumulated by retention compaction.
    case assistantTextSnapshot = "assistant_text_snapshot"
    /// The first update announcing a tool call.
    case toolCall = "tool_call"
    /// A subsequent state change for an announced tool call.
    case toolState = "tool_state"
    /// A permission request or its resolution.
    case permissionState = "permission_state"
    /// The terminal update for a Turn that produced a result.
    case completion
    /// The terminal update for a cancelled Turn.
    case cancellation
    /// The terminal update for a failed Turn.
    case error
}

/// The declared vocabulary of ``AscendantToolState/status`` values.
public enum AscendantToolStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// The tool call is announced but has not started executing.
    case pending
    /// The tool call is executing.
    case inProgress = "in_progress"
    /// The tool call finished successfully.
    case completed
    /// The tool call failed.
    case failed
}

/// The declared vocabulary of ``AscendantPermissionState/status`` values.
public enum AscendantPermissionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// The request is awaiting a decision.
    case pending
    /// The client approved the request.
    case selected
    /// The client denied the request.
    case denied
    /// The host withdrew the request because the connection was lost.
    case connectionLost = "connection_lost"
}


public struct AscendantToolState: Codable, Sendable, Equatable {
    public let toolCallID: String
    public let title: String?
    public let status: String
    public let content: String?

    public init(toolCallID: String, title: String? = nil, status: String, content: String? = nil) {
        self.toolCallID = toolCallID
        self.title = title
        self.status = status
        self.content = content
    }

    /// Creates a tool state from a declared status.
    public init(toolCallID: String, title: String? = nil, status: AscendantToolStatus, content: String? = nil) {
        self.init(toolCallID: toolCallID, title: title, status: status.rawValue, content: content)
    }

    /// The declared status, or `nil` when the peer sent a status this build
    /// does not know.
    public var toolStatus: AscendantToolStatus? { .init(rawValue: status) }
}

public struct AscendantPermissionState: Codable, Sendable, Equatable {
    public let correlationID: String
    public let toolCallID: String
    public let title: String
    public let status: String

    public init(correlationID: String, toolCallID: String, title: String, status: String) {
        self.correlationID = correlationID
        self.toolCallID = toolCallID
        self.title = title
        self.status = status
    }

    /// Creates a permission state from a declared status.
    public init(correlationID: String, toolCallID: String, title: String, status: AscendantPermissionStatus) {
        self.init(correlationID: correlationID, toolCallID: toolCallID, title: title, status: status.rawValue)
    }

    /// The declared status, or `nil` when the peer sent a status this build
    /// does not know.
    public var permissionStatus: AscendantPermissionStatus? { .init(rawValue: status) }
}

/// A replayable, transport-neutral update emitted for an identified Ascendant
/// turn. The ACP adapter maps these values to `session/update` notifications.
public struct AscendantTurnUpdate: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let sequence: Int
    public let kind: String
    public let text: String?
    public let toolState: AscendantToolState?
    public let toolStates: [AscendantToolState]
    public let permissionState: AscendantPermissionState?
    public let permissionStates: [AscendantPermissionState]
    public let terminal: Bool
    public let reasonCode: String?
    public let statusCode: Int?
    public let retryable: Bool?

    public init(
        sequence: Int,
        kind: String,
        text: String? = nil,
        toolState: AscendantToolState? = nil,
        toolStates: [AscendantToolState] = [],
        permissionState: AscendantPermissionState? = nil,
        permissionStates: [AscendantPermissionState] = [],
        terminal: Bool = false,
        reasonCode: String? = nil,
        statusCode: Int? = nil,
        retryable: Bool? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.sequence = sequence
        self.kind = kind
        self.text = text
        self.toolState = toolState
        self.toolStates = toolStates
        self.permissionState = permissionState
        self.permissionStates = permissionStates
        self.terminal = terminal
        self.reasonCode = reasonCode.map(GnosticWirePayload.boundedIdentifier)
        self.statusCode = statusCode.map(GnosticProtocol.boundedStatusCode)
        self.retryable = retryable
    }

    /// Creates an update from a declared kind.
    public init(
        sequence: Int,
        kind: AscendantTurnUpdateKind,
        text: String? = nil,
        toolState: AscendantToolState? = nil,
        toolStates: [AscendantToolState] = [],
        permissionState: AscendantPermissionState? = nil,
        permissionStates: [AscendantPermissionState] = [],
        terminal: Bool = false,
        reasonCode: String? = nil,
        statusCode: Int? = nil,
        retryable: Bool? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.init(
            sequence: sequence,
            kind: kind.rawValue,
            text: text,
            toolState: toolState,
            toolStates: toolStates,
            permissionState: permissionState,
            permissionStates: permissionStates,
            terminal: terminal,
            reasonCode: reasonCode,
            statusCode: statusCode,
            retryable: retryable,
            protocolMajor: protocolMajor
        )
    }

    /// The declared kind, or `nil` when the peer sent a kind this build does
    /// not know.
    public var updateKind: AscendantTurnUpdateKind? { .init(rawValue: kind) }

    /// Whether ``text`` holds assistant output, whether streamed live or
    /// accumulated by retention compaction.
    public var carriesAssistantText: Bool {
        switch updateKind {
        case .assistantText, .assistantTextSnapshot: true
        default: false
        }
    }

    /// Whether this update terminates its Turn without a result. A successful
    /// ``AscendantTurnUpdateKind/completion`` is terminal but not a failure.
    public var isTerminalFailure: Bool {
        switch updateKind {
        case .error, .cancellation: true
        default: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, sequence, kind, text, toolState, toolStates, permissionState, permissionStates, terminal, reasonCode, statusCode, retryable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        sequence = try container.decode(Int.self, forKey: .sequence)
        kind = try container.decode(String.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        toolState = try container.decodeIfPresent(AscendantToolState.self, forKey: .toolState)
        toolStates = try container.decodeIfPresent([AscendantToolState].self, forKey: .toolStates) ?? []
        permissionState = try container.decodeIfPresent(AscendantPermissionState.self, forKey: .permissionState)
        permissionStates = try container.decodeIfPresent([AscendantPermissionState].self, forKey: .permissionStates) ?? []
        terminal = try container.decode(Bool.self, forKey: .terminal)
        reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode).map(GnosticWirePayload.boundedIdentifier)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode).map(GnosticProtocol.boundedStatusCode)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable)
    }
}

public struct AscendantTurnReplay: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let updates: [AscendantTurnUpdate]
    public let compacted: Bool
    public let terminal: Bool
    public let conflict: Bool
    public let nextSequence: Int?

    public init(updates: [AscendantTurnUpdate], compacted: Bool, terminal: Bool, conflict: Bool = false, nextSequence: Int? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.updates = updates
        self.compacted = compacted
        self.terminal = terminal
        self.conflict = conflict
        self.nextSequence = nextSequence
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, updates, compacted, terminal, conflict, nextSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        updates = try container.decode([AscendantTurnUpdate].self, forKey: .updates)
        compacted = try container.decode(Bool.self, forKey: .compacted)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        conflict = try container.decodeIfPresent(Bool.self, forKey: .conflict) ?? false
        nextSequence = try container.decodeIfPresent(Int.self, forKey: .nextSequence)
    }
}
