// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Why foreground work stopped in an ACP v2 session.
public enum ACPStopReason: Codable, Sendable, Equatable {
    case endTurn
    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled
    case error(ACPJSONRPCError?)
    case other(String)

    private enum CodingKeys: String, CodingKey {
        case stopReason
        case error
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            self = Self.fromWire(value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .stopReason)
        if value == "error" {
            self = .error(try container.decodeIfPresent(ACPJSONRPCError.self, forKey: .error))
        } else {
            self = Self.fromWire(value)
        }
    }

    static func fromWire(_ value: String) -> ACPStopReason {
        switch value {
        case "end_turn": .endTurn
        case "max_tokens": .maxTokens
        case "max_turn_requests": .maxTurnRequests
        case "refusal": .refusal
        case "cancelled": .cancelled
        case "error": .error(nil)
        default: .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .error(error):
            if let error {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("error", forKey: .stopReason)
                try container.encode(error, forKey: .error)
            } else {
                var container = encoder.singleValueContainer()
                try container.encode("error")
            }
        default:
            var container = encoder.singleValueContainer()
            try container.encode(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .endTurn: "end_turn"
        case .maxTokens: "max_tokens"
        case .maxTurnRequests: "max_turn_requests"
        case .refusal: "refusal"
        case .cancelled: "cancelled"
        case .error: "error"
        case let .other(value): value
        }
    }
}

/// The state of the agent's foreground work in an ACP v2 session.
public enum ACPStateUpdate: Codable, Sendable, Equatable {
    case running(meta: [String: ACPValue]?)
    case idle(stopReason: ACPStopReason?, meta: [String: ACPValue]?)
    case requiresAction(meta: [String: ACPValue]?)
    case other(state: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case state
        case stopReason
        case error
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        let meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)

        switch state {
        case "running":
            self = .running(meta: meta)
        case "idle":
            let raw = try container.decodeIfPresent(String.self, forKey: .stopReason)
            switch raw {
            case "error"?:
                self = .idle(
                    stopReason: .error(try container.decodeIfPresent(ACPJSONRPCError.self, forKey: .error)),
                    meta: meta
                )
            case let value?:
                self = .idle(stopReason: ACPStopReason.fromWire(value), meta: meta)
            case nil:
                self = .idle(stopReason: nil, meta: meta)
            }
        case "requires_action":
            self = .requiresAction(meta: meta)
        default:
            let single = try decoder.singleValueContainer()
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "state")
            self = .other(state: state, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .running(meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("running", forKey: .state)
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .idle(stopReason, meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("idle", forKey: .state)
            if let stopReason {
                switch stopReason {
                case let .error(error):
                    try container.encode("error", forKey: .stopReason)
                    try container.encodeIfPresent(error, forKey: .error)
                default:
                    try container.encode(stopReason.wireValue, forKey: .stopReason)
                }
            }
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .requiresAction(meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("requires_action", forKey: .state)
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .other(state, fields):
            var combined = fields
            combined["state"] = .string(state)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }

    public var stateString: String {
        switch self {
        case .running: "running"
        case .idle: "idle"
        case .requiresAction: "requires_action"
        case let .other(state, _): state
        }
    }

    public var idleStopReason: ACPStopReason? {
        guard case let .idle(stopReason, _) = self else { return nil }
        return stopReason
    }
}

/// A chunk of streaming content within a message or thought.
public struct ACPContentChunk: Codable, Sendable, Equatable {
    public var messageId: String
    public var content: ACPContentBlock
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case messageId
        case content
        case meta = "_meta"
    }

    public init(messageId: String, content: ACPContentBlock, meta: [String: ACPValue]? = nil) {
        self.messageId = messageId
        self.content = content
        self.meta = meta
    }
}

/// A user message upsert update.
public struct ACPUserMessage: Codable, Sendable, Equatable {
    public var messageId: String
    public var content: [ACPContentBlock]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case messageId
        case content
        case meta = "_meta"
    }

    public init(messageId: String, content: [ACPContentBlock]? = nil, meta: [String: ACPValue]? = nil) {
        self.messageId = messageId
        self.content = content
        self.meta = meta
    }
}

/// An agent message upsert update.
public struct ACPAgentMessage: Codable, Sendable, Equatable {
    public var messageId: String
    public var content: [ACPContentBlock]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case messageId
        case content
        case meta = "_meta"
    }

    public init(messageId: String, content: [ACPContentBlock]? = nil, meta: [String: ACPValue]? = nil) {
        self.messageId = messageId
        self.content = content
        self.meta = meta
    }
}

/// An agent thought / internal reasoning upsert update.
public struct ACPAgentThought: Codable, Sendable, Equatable {
    public var messageId: String
    public var content: [ACPContentBlock]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case messageId
        case content
        case meta = "_meta"
    }

    public init(messageId: String, content: [ACPContentBlock]? = nil, meta: [String: ACPValue]? = nil) {
        self.messageId = messageId
        self.content = content
        self.meta = meta
    }
}

/// Terminal reference in ACP v2 tool-call output.
public struct ACPTerminal: Codable, Sendable, Equatable {
    public var type: String
    public var terminalId: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case terminalId
        case meta = "_meta"
    }

    public init(terminalId: String, meta: [String: ACPValue]? = nil) {
        self.type = "terminal"
        self.terminalId = terminalId
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "terminal"
        self.terminalId = try container.decode(String.self, forKey: .terminalId)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }
}

/// Tool call content variants in ACP v2.
public enum ACPToolCallContent: Codable, Sendable, Equatable {
    case content(ACPContent)
    case diff(ACPDiff)
    case terminal(ACPTerminal)
    case other(type: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case changes
        case patch
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch type {
        case "content":
            self = .content(try single.decode(ACPContent.self))
        case "diff":
            self = .diff(try single.decode(ACPDiff.self))
        case "terminal":
            self = .terminal(try single.decode(ACPTerminal.self))
        default:
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "type")
            self = .other(type: type, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .content(content):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("content", forKey: .type)
            try container.encode(content, forKey: .content)
        case let .diff(diff):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("diff", forKey: .type)
            try container.encode(diff.changes, forKey: .changes)
            try container.encodeIfPresent(diff.patch, forKey: .patch)
            try container.encodeIfPresent(diff.meta, forKey: .meta)
        case let .terminal(terminal):
            try terminal.encode(to: encoder)
        case let .other(type, fields):
            var combined = fields
            combined["type"] = .string(type)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }
}

/// A chunk of tool call content streamed in an ACP v2 session.
public struct ACPToolCallContentChunk: Codable, Sendable, Equatable {
    public var toolCallId: String
    public var content: ACPToolCallContent
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case toolCallId
        case content
        case meta = "_meta"
    }

    public init(toolCallId: String, content: ACPToolCallContent, meta: [String: ACPValue]? = nil) {
        self.toolCallId = toolCallId
        self.content = content
        self.meta = meta
    }
}

/// A tool call created or updated in an ACP v2 session.
public struct ACPToolCallUpdate: Codable, Sendable, Equatable {
    public var toolCallId: String
    public var name: String?
    public var title: String?
    public var kind: String?
    public var status: String?
    public var content: [ACPToolCallContent]?
    public var locations: [ACPToolCallLocation]?
    public var rawInput: ACPValue?
    public var rawOutput: ACPValue?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case toolCallId
        case name
        case title
        case kind
        case status
        case content
        case locations
        case rawInput
        case rawOutput
        case meta = "_meta"
    }

    public init(
        toolCallId: String,
        name: String? = nil,
        title: String? = nil,
        kind: String? = nil,
        status: String? = nil,
        content: [ACPToolCallContent]? = nil,
        locations: [ACPToolCallLocation]? = nil,
        rawInput: ACPValue? = nil,
        rawOutput: ACPValue? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.toolCallId = toolCallId
        self.name = name
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.meta = meta
    }
}

/// Authoritative replacement output snapshot for an agent-owned terminal.
public struct ACPTerminalOutput: Codable, Sendable, Equatable {
    public var data: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case data
        case meta = "_meta"
    }

    public init(data: String, meta: [String: ACPValue]? = nil) {
        self.data = data
        self.meta = meta
    }
}

/// Exit information for an agent-owned terminal.
public struct ACPTerminalExitStatus: Codable, Sendable, Equatable {
    public var exitCode: Int?
    public var signal: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case exitCode
        case signal
        case meta = "_meta"
    }

    public init(exitCode: Int? = nil, signal: String? = nil, meta: [String: ACPValue]? = nil) {
        self.exitCode = exitCode
        self.signal = signal
        self.meta = meta
    }
}

/// Terminal state update in an ACP v2 session.
public struct ACPTerminalUpdate: Codable, Sendable, Equatable {
    public var terminalId: String
    public var command: String?
    public var cwd: String?
    public var output: ACPTerminalOutput?
    public var exitStatus: ACPTerminalExitStatus?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case terminalId
        case command
        case cwd
        case output
        case exitStatus
        case meta = "_meta"
    }

    public init(
        terminalId: String,
        command: String? = nil,
        cwd: String? = nil,
        output: ACPTerminalOutput? = nil,
        exitStatus: ACPTerminalExitStatus? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.terminalId = terminalId
        self.command = command
        self.cwd = cwd
        self.output = output
        self.exitStatus = exitStatus
        self.meta = meta
    }
}

/// Terminal output chunk streamed in an ACP v2 session.
public struct ACPTerminalOutputChunk: Codable, Sendable, Equatable {
    public var terminalId: String
    public var data: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case terminalId
        case data
        case meta = "_meta"
    }

    public init(terminalId: String, data: String, meta: [String: ACPValue]? = nil) {
        self.terminalId = terminalId
        self.data = data
        self.meta = meta
    }
}

/// Plan entry in an ACP v2 plan update.
public struct ACPPlanEntry: Codable, Sendable, Equatable {
    public var content: String
    public var priority: String
    public var status: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case content
        case priority
        case status
        case meta = "_meta"
    }

    public init(content: String, priority: String, status: String, meta: [String: ACPValue]? = nil) {
        self.content = content
        self.priority = priority
        self.status = status
        self.meta = meta
    }
}

/// Updated content for a plan.
public enum ACPPlanContent: Codable, Sendable, Equatable {
    case items(planId: String, entries: [ACPPlanEntry], meta: [String: ACPValue]?)
    case other(type: String, planId: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case type
        case planId
        case entries
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let planId = try container.decode(String.self, forKey: .planId)
        if type == "items" {
            self = .items(
                planId: planId,
                entries: try container.decode([ACPPlanEntry].self, forKey: .entries),
                meta: try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
            )
        } else {
            let single = try decoder.singleValueContainer()
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "type")
            fields.removeValue(forKey: "planId")
            self = .other(type: type, planId: planId, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .items(planId, entries, meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("items", forKey: .type)
            try container.encode(planId, forKey: .planId)
            try container.encode(entries, forKey: .entries)
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .other(type, planId, fields):
            var combined = fields
            combined["type"] = .string(type)
            combined["planId"] = .string(planId)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }
}

/// Plan update in an ACP v2 session.
public struct ACPPlanUpdate: Codable, Sendable, Equatable {
    public var plan: ACPPlanContent
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case plan
        case meta = "_meta"
    }

    public init(plan: ACPPlanContent, meta: [String: ACPValue]? = nil) {
        self.plan = plan
        self.meta = meta
    }
}

/// Available commands update in an ACP v2 session.
public struct ACPAvailableCommandsUpdate: Codable, Sendable, Equatable {
    public var availableCommands: [ACPValue]
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case availableCommands
        case meta = "_meta"
    }

    public init(availableCommands: [ACPValue], meta: [String: ACPValue]? = nil) {
        self.availableCommands = availableCommands
        self.meta = meta
    }
}

/// Configuration option update in an ACP v2 session.
public struct ACPConfigOptionUpdate: Codable, Sendable, Equatable {
    public var configOptions: [ACPValue]
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case configOptions
        case meta = "_meta"
    }

    public init(configOptions: [ACPValue], meta: [String: ACPValue]? = nil) {
        self.configOptions = configOptions
        self.meta = meta
    }
}

/// Session info update in an ACP v2 session.
public struct ACPSessionInfoUpdate: Codable, Sendable, Equatable {
    public var title: String?
    public var updatedAt: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case title
        case updatedAt
        case meta = "_meta"
    }

    public init(title: String? = nil, updatedAt: String? = nil, meta: [String: ACPValue]? = nil) {
        self.title = title
        self.updatedAt = updatedAt
        self.meta = meta
    }
}

/// Cost metrics in usage update.
public struct ACPCost: Codable, Sendable, Equatable {
    public var amount: Double
    public var currency: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case amount
        case currency
        case meta = "_meta"
    }

    public init(amount: Double, currency: String, meta: [String: ACPValue]? = nil) {
        self.amount = amount
        self.currency = currency
        self.meta = meta
    }
}

/// Usage update in an ACP v2 session.
public struct ACPUsageUpdate: Codable, Sendable, Equatable {
    public var used: Int
    public var size: Int
    public var cost: ACPCost?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case used
        case size
        case cost
        case meta = "_meta"
    }

    public init(used: Int, size: Int, cost: ACPCost? = nil, meta: [String: ACPValue]? = nil) {
        self.used = used
        self.size = size
        self.cost = cost
        self.meta = meta
    }
}

/// Notice update in an ACP v2 session.
public struct ACPNotice: Codable, Sendable, Equatable {
    public var severity: String
    public var title: String
    public var description: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case severity
        case title
        case description
        case meta = "_meta"
    }

    public init(
        severity: String,
        title: String,
        description: String? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.severity = severity
        self.title = title
        self.description = description
        self.meta = meta
    }
}

/// Context compaction update in an ACP v2 session.
public struct ACPCompactionUpdate: Codable, Sendable, Equatable {
    public var compactionId: String
    public var status: String
    public var summary: [ACPContentBlock]?
    public var error: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case compactionId
        case status
        case summary
        case error
        case meta = "_meta"
    }

    public init(
        compactionId: String,
        status: String,
        summary: [ACPContentBlock]? = nil,
        error: String? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.compactionId = compactionId
        self.status = status
        self.summary = summary
        self.error = error
        self.meta = meta
    }
}

/// Context compaction summary chunk in an ACP v2 session.
public struct ACPCompactionSummaryChunk: Codable, Sendable, Equatable {
    public var compactionId: String
    public var content: ACPContentBlock
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case compactionId
        case content
        case meta = "_meta"
    }

    public init(compactionId: String, content: ACPContentBlock, meta: [String: ACPValue]? = nil) {
        self.compactionId = compactionId
        self.content = content
        self.meta = meta
    }
}

/// Master ACP v2 SessionUpdate enumeration.
///
/// Fully extensible: unknown update kinds round-trip losslessly as `.other(sessionUpdate:fields:)`.
public enum ACPSessionUpdate: Codable, Sendable, Equatable {
    case userMessageChunk(ACPContentChunk)
    case userMessage(ACPUserMessage)
    case agentMessageChunk(ACPContentChunk)
    case agentMessage(ACPAgentMessage)
    case agentThoughtChunk(ACPContentChunk)
    case agentThought(ACPAgentThought)
    case stateUpdate(ACPStateUpdate)
    case toolCallContentChunk(ACPToolCallContentChunk)
    case toolCallUpdate(ACPToolCallUpdate)
    case terminalUpdate(ACPTerminalUpdate)
    case terminalOutputChunk(ACPTerminalOutputChunk)
    case planUpdate(ACPPlanUpdate)
    case availableCommandsUpdate(ACPAvailableCommandsUpdate)
    case configOptionUpdate(ACPConfigOptionUpdate)
    case sessionInfoUpdate(ACPSessionInfoUpdate)
    case usageUpdate(ACPUsageUpdate)
    case notice(ACPNotice)
    case compactionUpdate(ACPCompactionUpdate)
    case compactionSummaryChunk(ACPCompactionSummaryChunk)
    case other(sessionUpdate: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        let single = try decoder.singleValueContainer()

        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(try single.decode(ACPContentChunk.self))
        case "user_message":
            self = .userMessage(try single.decode(ACPUserMessage.self))
        case "agent_message_chunk":
            self = .agentMessageChunk(try single.decode(ACPContentChunk.self))
        case "agent_message":
            self = .agentMessage(try single.decode(ACPAgentMessage.self))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try single.decode(ACPContentChunk.self))
        case "agent_thought":
            self = .agentThought(try single.decode(ACPAgentThought.self))
        case "state_update":
            self = .stateUpdate(try single.decode(ACPStateUpdate.self))
        case "tool_call_content_chunk":
            self = .toolCallContentChunk(try single.decode(ACPToolCallContentChunk.self))
        case "tool_call_update":
            self = .toolCallUpdate(try single.decode(ACPToolCallUpdate.self))
        case "terminal_update":
            self = .terminalUpdate(try single.decode(ACPTerminalUpdate.self))
        case "terminal_output_chunk":
            self = .terminalOutputChunk(try single.decode(ACPTerminalOutputChunk.self))
        case "plan_update":
            self = .planUpdate(try single.decode(ACPPlanUpdate.self))
        case "available_commands_update":
            self = .availableCommandsUpdate(try single.decode(ACPAvailableCommandsUpdate.self))
        case "config_option_update":
            self = .configOptionUpdate(try single.decode(ACPConfigOptionUpdate.self))
        case "session_info_update":
            self = .sessionInfoUpdate(try single.decode(ACPSessionInfoUpdate.self))
        case "usage_update":
            self = .usageUpdate(try single.decode(ACPUsageUpdate.self))
        case "notice":
            self = .notice(try single.decode(ACPNotice.self))
        case "compaction_update":
            self = .compactionUpdate(try single.decode(ACPCompactionUpdate.self))
        case "compaction_summary_chunk":
            self = .compactionSummaryChunk(try single.decode(ACPCompactionSummaryChunk.self))
        default:
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "sessionUpdate")
            self = .other(sessionUpdate: kind, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        func encodeTagged<T: Encodable>(_ kind: String, value: T) throws {
            let data = try JSONEncoder().encode(value)
            var dictionary = try JSONDecoder().decode([String: ACPValue].self, from: data)
            dictionary["sessionUpdate"] = .string(kind)
            var container = encoder.singleValueContainer()
            try container.encode(dictionary)
        }

        switch self {
        case let .userMessageChunk(value): try encodeTagged("user_message_chunk", value: value)
        case let .userMessage(value): try encodeTagged("user_message", value: value)
        case let .agentMessageChunk(value): try encodeTagged("agent_message_chunk", value: value)
        case let .agentMessage(value): try encodeTagged("agent_message", value: value)
        case let .agentThoughtChunk(value): try encodeTagged("agent_thought_chunk", value: value)
        case let .agentThought(value): try encodeTagged("agent_thought", value: value)
        case let .stateUpdate(value): try encodeTagged("state_update", value: value)
        case let .toolCallContentChunk(value): try encodeTagged("tool_call_content_chunk", value: value)
        case let .toolCallUpdate(value): try encodeTagged("tool_call_update", value: value)
        case let .terminalUpdate(value): try encodeTagged("terminal_update", value: value)
        case let .terminalOutputChunk(value): try encodeTagged("terminal_output_chunk", value: value)
        case let .planUpdate(value): try encodeTagged("plan_update", value: value)
        case let .availableCommandsUpdate(value): try encodeTagged("available_commands_update", value: value)
        case let .configOptionUpdate(value): try encodeTagged("config_option_update", value: value)
        case let .sessionInfoUpdate(value): try encodeTagged("session_info_update", value: value)
        case let .usageUpdate(value): try encodeTagged("usage_update", value: value)
        case let .notice(value): try encodeTagged("notice", value: value)
        case let .compactionUpdate(value): try encodeTagged("compaction_update", value: value)
        case let .compactionSummaryChunk(value): try encodeTagged("compaction_summary_chunk", value: value)
        case let .other(kind, fields):
            var combined = fields
            combined["sessionUpdate"] = .string(kind)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }

    public var updateKind: String {
        switch self {
        case .userMessageChunk: "user_message_chunk"
        case .userMessage: "user_message"
        case .agentMessageChunk: "agent_message_chunk"
        case .agentMessage: "agent_message"
        case .agentThoughtChunk: "agent_thought_chunk"
        case .agentThought: "agent_thought"
        case .stateUpdate: "state_update"
        case .toolCallContentChunk: "tool_call_content_chunk"
        case .toolCallUpdate: "tool_call_update"
        case .terminalUpdate: "terminal_update"
        case .terminalOutputChunk: "terminal_output_chunk"
        case .planUpdate: "plan_update"
        case .availableCommandsUpdate: "available_commands_update"
        case .configOptionUpdate: "config_option_update"
        case .sessionInfoUpdate: "session_info_update"
        case .usageUpdate: "usage_update"
        case .notice: "notice"
        case .compactionUpdate: "compaction_update"
        case .compactionSummaryChunk: "compaction_summary_chunk"
        case let .other(kind, _): kind
        }
    }
}
