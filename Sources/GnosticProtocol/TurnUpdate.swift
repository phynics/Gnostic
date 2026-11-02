// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The declared vocabulary of ``TurnUpdate/kind`` values.
///
/// The wire representation stays a `String` so that a peer emitting a kind
/// from a newer build decodes without loss. Use ``TurnUpdate/updateKind``
/// to read a kind that this build understands.
public enum TurnUpdateKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Incremental assistant output produced while a Turn runs.
    case assistantText = "assistant_text"
    /// Assistant output accumulated by retention compaction.
    case assistantTextSnapshot = "assistant_text_snapshot"
    /// Incremental Runtime thought (reasoning) text. It is never assistant text.
    case thought
    /// The Runtime's current plan. Each update holds the whole plan and replaces
    /// the plan with the same ``TurnPlan/planID``.
    case plan
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

/// The declared vocabulary of ``TurnToolState/status`` values.
public enum TurnToolStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// The tool call is announced but has not started executing.
    case pending
    /// The tool call is executing.
    case inProgress = "in_progress"
    /// The tool call finished successfully.
    case completed
    /// The tool call failed.
    case failed
}

/// The declared vocabulary of ``TurnPermissionState/status`` values.
public enum TurnPermissionStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// The request is awaiting a decision.
    case pending
    /// The client approved the request.
    case selected
    /// The client denied the request.
    case denied
    /// The host could not commit or mediate the permission decision.
    case unavailable
    /// The host withdrew the request because the connection was lost.
    case connectionLost = "connection_lost"
}


/// One step of a ``TurnPlan``.
public struct TurnPlanEntry: Codable, Sendable, Equatable {
    /// The step's description, at most 120 bytes. A longer one ends in ``TurnUpdate/truncationMarker``.
    public let content: String
    /// The Runtime's priority, usually `high`, `medium` or `low`.
    public let priority: String
    /// The Runtime's status, usually `pending`, `in_progress` or `completed`.
    public let status: String

    public init(content: String, priority: String, status: String) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

/// A Runtime plan, bounded to fit one ``TurnUpdate``.
///
/// A plan update replaces the plan with the same ``planID``: it holds every step,
/// not a change to the previous plan. A consumer replaces and never appends. A plan
/// over the bound keeps its leading entries and sets ``truncated``. The journal
/// keeps the whole plan.
public struct TurnPlan: Codable, Sendable, Equatable {
    /// The Runtime's plan identifier.
    public let planID: String
    /// The plan's steps, in order. At most 32, and fewer when they do not fit one update.
    public let entries: [TurnPlanEntry]
    /// Whether the plan lost entries to the bound. The rendered ACP plan then ends in a
    /// marker entry.
    public let truncated: Bool

    public init(planID: String, entries: [TurnPlanEntry], truncated: Bool = false) {
        self.planID = planID
        self.entries = entries
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey { case planID, entries, truncated }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planID = try container.decode(String.self, forKey: .planID)
        entries = try container.decode([TurnPlanEntry].self, forKey: .entries)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

public struct TurnToolState: Codable, Sendable, Equatable {
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
    public init(toolCallID: String, title: String? = nil, status: TurnToolStatus, content: String? = nil) {
        self.init(toolCallID: toolCallID, title: title, status: status.rawValue, content: content)
    }

    /// The declared status, or `nil` when the peer sent a status this build
    /// does not know.
    public var toolStatus: TurnToolStatus? { .init(rawValue: status) }
}

public struct TurnPermissionState: Codable, Sendable, Equatable {
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
    public init(correlationID: String, toolCallID: String, title: String, status: TurnPermissionStatus) {
        self.init(correlationID: correlationID, toolCallID: toolCallID, title: title, status: status.rawValue)
    }

    /// The declared status, or `nil` when the peer sent a status this build
    /// does not know.
    public var permissionStatus: TurnPermissionStatus? { .init(rawValue: status) }
}

/// A replayable, transport-neutral update emitted for an identified
/// Turn. The ACP adapter maps these values to `session/update` notifications.
public struct TurnUpdate: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let sequence: Int
    public let kind: String
    public let text: String?
    public let toolState: TurnToolState?
    public let toolStates: [TurnToolState]
    public let permissionState: TurnPermissionState?
    public let permissionStates: [TurnPermissionState]
    /// The plan of a ``TurnUpdateKind/plan`` update.
    public let plan: TurnPlan?
    /// The latest plan for each plan ID that retention folded into a snapshot.
    public let plans: [TurnPlan]
    public let terminal: Bool
    public let reasonCode: String?
    public let statusCode: Int?
    public let retryable: Bool?

    public init(
        sequence: Int,
        kind: String,
        text: String? = nil,
        toolState: TurnToolState? = nil,
        toolStates: [TurnToolState] = [],
        permissionState: TurnPermissionState? = nil,
        permissionStates: [TurnPermissionState] = [],
        plan: TurnPlan? = nil,
        plans: [TurnPlan] = [],
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
        self.plan = plan
        self.plans = plans
        self.terminal = terminal
        self.reasonCode = reasonCode.map(GnosticWirePayload.boundedIdentifier)
        self.statusCode = statusCode.map(GnosticProtocol.boundedStatusCode)
        self.retryable = retryable
    }

    /// Creates an update from a declared kind.
    public init(
        sequence: Int,
        kind: TurnUpdateKind,
        text: String? = nil,
        toolState: TurnToolState? = nil,
        toolStates: [TurnToolState] = [],
        permissionState: TurnPermissionState? = nil,
        permissionStates: [TurnPermissionState] = [],
        plan: TurnPlan? = nil,
        plans: [TurnPlan] = [],
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
            plan: plan,
            plans: plans,
            terminal: terminal,
            reasonCode: reasonCode,
            statusCode: statusCode,
            retryable: retryable,
            protocolMajor: protocolMajor
        )
    }

    /// The declared kind, or `nil` when the peer sent a kind this build does
    /// not know.
    public var updateKind: TurnUpdateKind? { .init(rawValue: kind) }

    /// Ends text that retention or a size bound cut.
    package static let truncationMarker = "…[truncated]"

    /// The sequence of a router's report that it lost a Turn's owner. Real
    /// updates start at 1, so this can never be saved as a replay cursor.
    package static let observationLostSequence = 0

    /// Whether ``text`` holds assistant output, whether streamed live or
    /// accumulated by retention compaction.
    public var carriesAssistantText: Bool {
        switch updateKind {
        case .assistantText, .assistantTextSnapshot: true
        default: false
        }
    }

    /// Whether this update terminates its Turn without a result. A successful
    /// ``TurnUpdateKind/completion`` is terminal but not a failure.
    public var isTerminalFailure: Bool {
        switch updateKind {
        case .error, .cancellation: true
        default: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, sequence, kind, text, toolState, toolStates, permissionState, permissionStates, plan, plans, terminal, reasonCode, statusCode, retryable
    }

    /// Omits an empty ``plans`` so an update without a plan encodes as it did before plans existed.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(toolState, forKey: .toolState)
        try container.encode(toolStates, forKey: .toolStates)
        try container.encodeIfPresent(permissionState, forKey: .permissionState)
        try container.encode(permissionStates, forKey: .permissionStates)
        try container.encodeIfPresent(plan, forKey: .plan)
        if !plans.isEmpty { try container.encode(plans, forKey: .plans) }
        try container.encode(terminal, forKey: .terminal)
        try container.encodeIfPresent(reasonCode, forKey: .reasonCode)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(retryable, forKey: .retryable)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        sequence = try container.decode(Int.self, forKey: .sequence)
        kind = try container.decode(String.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        toolState = try container.decodeIfPresent(TurnToolState.self, forKey: .toolState)
        toolStates = try container.decodeIfPresent([TurnToolState].self, forKey: .toolStates) ?? []
        permissionState = try container.decodeIfPresent(TurnPermissionState.self, forKey: .permissionState)
        permissionStates = try container.decodeIfPresent([TurnPermissionState].self, forKey: .permissionStates) ?? []
        plan = try container.decodeIfPresent(TurnPlan.self, forKey: .plan)
        plans = try container.decodeIfPresent([TurnPlan].self, forKey: .plans) ?? []
        terminal = try container.decode(Bool.self, forKey: .terminal)
        reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode).map(GnosticWirePayload.boundedIdentifier)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode).map(GnosticProtocol.boundedStatusCode)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable)
    }
}

/// One page of the retained updates for an identified Turn.
///
/// A replay returns the updates whose sequence is greater than the requested
/// `afterSequence`, in order, up to the wire payload bound. A consumer drains
/// the pages before it concludes anything. See `Documentation/Compatibility/0.5.0.md`,
/// "Observe a Turn and reconnect".
public struct TurnReplay: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    /// The updates of this page, in sequence order.
    public let updates: [TurnUpdate]
    /// Whether retention folded updates that the caller's cursor had not passed.
    /// The first update can then be an ``TurnUpdateKind/assistantTextSnapshot``
    /// that holds the older text.
    public let compacted: Bool
    /// Whether the Turn has reached its terminal update. It can be `true` while
    /// more pages remain, so drain every page even when it is `true`.
    public let terminal: Bool
    /// Whether the supplied message differs from the one recorded under this
    /// client Turn ID. A conflicting replay has no updates and is `terminal`,
    /// which says nothing about the caller's own Turn.
    public let conflict: Bool
    /// `nil` on the last page. When another page remains, the **last sequence
    /// this page returned**, not the next event number. Pass it unchanged as
    /// `afterSequence` in the next replay. Adding one skips an update.
    public let nextSequence: Int?

    public init(updates: [TurnUpdate], compacted: Bool, terminal: Bool, conflict: Bool = false, nextSequence: Int? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
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
        updates = try container.decode([TurnUpdate].self, forKey: .updates)
        compacted = try container.decode(Bool.self, forKey: .compacted)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        conflict = try container.decodeIfPresent(Bool.self, forKey: .conflict) ?? false
        nextSequence = try container.decodeIfPresent(Int.self, forKey: .nextSequence)
    }
}
