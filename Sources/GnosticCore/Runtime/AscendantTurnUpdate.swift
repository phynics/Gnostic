// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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
}

/// A replayable, transport-neutral update emitted for an identified Ascendant
/// turn. The ACP adapter maps these values to `session/update` notifications.
public struct AscendantTurnUpdate: Codable, Sendable, Equatable {
    public let sequence: Int
    public let kind: String
    public let text: String?
    public let toolState: AscendantToolState?
    public let toolStates: [AscendantToolState]
    public let permissionState: AscendantPermissionState?
    public let permissionStates: [AscendantPermissionState]
    public let terminal: Bool

    public init(
        sequence: Int,
        kind: String,
        text: String? = nil,
        toolState: AscendantToolState? = nil,
        toolStates: [AscendantToolState] = [],
        permissionState: AscendantPermissionState? = nil,
        permissionStates: [AscendantPermissionState] = [],
        terminal: Bool = false
    ) {
        self.sequence = sequence
        self.kind = kind
        self.text = text
        self.toolState = toolState
        self.toolStates = toolStates
        self.permissionState = permissionState
        self.permissionStates = permissionStates
        self.terminal = terminal
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, kind, text, toolState, toolStates, permissionState, permissionStates, terminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int.self, forKey: .sequence)
        kind = try container.decode(String.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        toolState = try container.decodeIfPresent(AscendantToolState.self, forKey: .toolState)
        toolStates = try container.decodeIfPresent([AscendantToolState].self, forKey: .toolStates) ?? []
        permissionState = try container.decodeIfPresent(AscendantPermissionState.self, forKey: .permissionState)
        permissionStates = try container.decodeIfPresent([AscendantPermissionState].self, forKey: .permissionStates) ?? []
        terminal = try container.decode(Bool.self, forKey: .terminal)
    }
}

public struct AscendantTurnReplay: Codable, Sendable, Equatable {
    public let updates: [AscendantTurnUpdate]
    public let compacted: Bool
    public let terminal: Bool
    public let conflict: Bool

    public init(updates: [AscendantTurnUpdate], compacted: Bool, terminal: Bool, conflict: Bool = false) {
        self.updates = updates
        self.compacted = compacted
        self.terminal = terminal
        self.conflict = conflict
    }

    private enum CodingKeys: String, CodingKey {
        case updates, compacted, terminal, conflict
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updates = try container.decode([AscendantTurnUpdate].self, forKey: .updates)
        compacted = try container.decode(Bool.self, forKey: .compacted)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        conflict = try container.decodeIfPresent(Bool.self, forKey: .conflict) ?? false
    }
}
