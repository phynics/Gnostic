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
        // Can be decoded either from a string or from an object with { "stopReason": "...", "error": ... }
        if let single = try? decoder.singleValueContainer(), let str = try? single.decode(String.self) {
            switch str {
            case "end_turn": self = .endTurn
            case "max_tokens": self = .maxTokens
            case "max_turn_requests": self = .maxTurnRequests
            case "refusal": self = .refusal
            case "cancelled": self = .cancelled
            case "error": self = .error(nil)
            default: self = .other(str)
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reason = try container.decode(String.self, forKey: .stopReason)
        switch reason {
        case "end_turn":
            self = .endTurn
        case "max_tokens":
            self = .maxTokens
        case "max_turn_requests":
            self = .maxTurnRequests
        case "refusal":
            self = .refusal
        case "cancelled":
            self = .cancelled
        case "error":
            let err = try container.decodeIfPresent(ACPJSONRPCError.self, forKey: .error)
            self = .error(err)
        default:
            self = .other(reason)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .endTurn:
            var container = encoder.singleValueContainer()
            try container.encode("end_turn")
        case .maxTokens:
            var container = encoder.singleValueContainer()
            try container.encode("max_tokens")
        case .maxTurnRequests:
            var container = encoder.singleValueContainer()
            try container.encode("max_turn_requests")
        case .refusal:
            var container = encoder.singleValueContainer()
            try container.encode("refusal")
        case .cancelled:
            var container = encoder.singleValueContainer()
            try container.encode("cancelled")
        case let .error(err):
            if let err {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("error", forKey: .stopReason)
                try container.encode(err, forKey: .error)
            } else {
                var container = encoder.singleValueContainer()
                try container.encode("error")
            }
        case let .other(str):
            var container = encoder.singleValueContainer()
            try container.encode(str)
        }
    }

    public var wireValue: String {
        switch self {
        case .endTurn: return "end_turn"
        case .maxTokens: return "max_tokens"
        case .maxTurnRequests: return "max_turn_requests"
        case .refusal: return "refusal"
        case .cancelled: return "cancelled"
        case .error: return "error"
        case let .other(str): return str
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
            var stopReason: ACPStopReason?
            if let strReason = try? container.decodeIfPresent(String.self, forKey: .stopReason) {
                if strReason == "error" {
                    let err = try? container.decodeIfPresent(ACPJSONRPCError.self, forKey: .error)
                    stopReason = .error(err)
                } else {
                    stopReason = try? container.decodeIfPresent(ACPStopReason.self, forKey: .stopReason)
                }
            } else if let structuredReason = try? container.decodeIfPresent(ACPStopReason.self, forKey: .stopReason) {
                stopReason = structuredReason
            }
            self = .idle(stopReason: stopReason, meta: meta)
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
                case let .error(err):
                    try container.encode("error", forKey: .stopReason)
                    try container.encodeIfPresent(err, forKey: .error)
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
        case .running: return "running"
        case .idle: return "idle"
        case .requiresAction: return "requires_action"
        case let .other(state, _): return state
        }
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

/// Structured diff representation in ACP v2.
public struct ACPDiff: Codable, Sendable, Equatable {
    public var path: String?
    public var oldPath: String?
    public var patch: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case path
        case oldPath
        case patch
        case meta = "_meta"
    }

    public init(path: String? = nil, oldPath: String? = nil, patch: String? = nil, meta: [String: ACPValue]? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.patch = patch
        self.meta = meta
    }
}

/// Terminal reference in ACP v2 tool-call output.
public struct ACPTerminal: Codable, Sendable, Equatable {
    public var terminalId: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case terminalId
        case meta = "_meta"
    }

    public init(terminalId: String, meta: [String: ACPValue]? = nil) {
        self.terminalId = terminalId
        self.meta = meta
    }
}

/// Tool call content variants in ACP v2.
public enum ACPToolCallContent: Codable, Sendable, Equatable {
    case content(ACPContentBlock)
    case diff(ACPDiff)
    case terminal(ACPTerminal)
    case other(type: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let type = try? container?.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()

        if let type {
            switch type {
            case "diff":
                self = .diff(try single.decode(ACPDiff.self))
                return
            case "terminal":
                self = .terminal(try single.decode(ACPTerminal.self))
                return
            default:
                if let block = try? single.decode(ACPContentBlock.self) {
                    self = .content(block)
                    return
                }
                var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
                fields.removeValue(forKey: "type")
                self = .other(type: type, fields: fields)
                return
            }
        }
        if let block = try? single.decode(ACPContentBlock.self) {
            self = .content(block)
        } else {
            let fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            self = .other(type: "unknown", fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .content(block):
            try block.encode(to: encoder)
        case let .diff(d):
            var container = encoder.singleValueContainer()
            var dict = (try? JSONDecoder().decode([String: ACPValue].self, from: JSONEncoder().encode(d))) ?? [:]
            dict["type"] = .string("diff")
            try container.encode(dict)
        case let .terminal(term):
            var container = encoder.singleValueContainer()
            var dict = (try? JSONDecoder().decode([String: ACPValue].self, from: JSONEncoder().encode(term))) ?? [:]
            dict["type"] = .string("terminal")
            try container.encode(dict)
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
    public var title: String?
    public var kind: String?
    public var status: String?
    public var content: [ACPToolCallContent]?
    public var rawOutput: ACPValue?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case toolCallId
        case title
        case kind
        case status
        case content
        case rawOutput
        case meta = "_meta"
    }

    public init(
        toolCallId: String,
        title: String? = nil,
        kind: String? = nil,
        status: String? = nil,
        content: [ACPToolCallContent]? = nil,
        rawOutput: ACPValue? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.rawOutput = rawOutput
        self.meta = meta
    }
}

/// Terminal state update in an ACP v2 session.
public struct ACPTerminalUpdate: Codable, Sendable, Equatable {
    public var terminalId: String
    public var exitStatus: Int?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case terminalId
        case exitStatus
        case meta = "_meta"
    }

    public init(terminalId: String, exitStatus: Int? = nil, meta: [String: ACPValue]? = nil) {
        self.terminalId = terminalId
        self.exitStatus = exitStatus
        self.meta = meta
    }
}

/// Terminal output chunk streamed in an ACP v2 session.
public struct ACPTerminalOutputChunk: Codable, Sendable, Equatable {
    public var terminalId: String
    public var output: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case terminalId
        case output
        case meta = "_meta"
    }

    public init(terminalId: String, output: String, meta: [String: ACPValue]? = nil) {
        self.terminalId = terminalId
        self.output = output
        self.meta = meta
    }
}

/// Plan entry in an ACP v2 plan update.
public struct ACPPlanEntry: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: String
    public var priority: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case priority
        case meta = "_meta"
    }

    public init(id: String, title: String, status: String, priority: String? = nil, meta: [String: ACPValue]? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.meta = meta
    }
}

/// Plan update in an ACP v2 session.
public struct ACPPlanUpdate: Codable, Sendable, Equatable {
    public var planId: String?
    public var entries: [ACPPlanEntry]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case planId
        case entries
        case meta = "_meta"
    }

    public init(planId: String? = nil, entries: [ACPPlanEntry]? = nil, meta: [String: ACPValue]? = nil) {
        self.planId = planId
        self.entries = entries
        self.meta = meta
    }
}

/// Plan removed notice (unstable) in an ACP v2 session.
public struct ACPPlanRemoved: Codable, Sendable, Equatable {
    public var planId: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case planId
        case meta = "_meta"
    }

    public init(planId: String, meta: [String: ACPValue]? = nil) {
        self.planId = planId
        self.meta = meta
    }
}

/// Available commands update in an ACP v2 session.
public struct ACPAvailableCommandsUpdate: Codable, Sendable, Equatable {
    public var commands: [ACPValue]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case commands
        case meta = "_meta"
    }

    public init(commands: [ACPValue]? = nil, meta: [String: ACPValue]? = nil) {
        self.commands = commands
        self.meta = meta
    }
}

/// Configuration option update in an ACP v2 session.
public struct ACPConfigOptionUpdate: Codable, Sendable, Equatable {
    public var options: [ACPValue]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case options
        case meta = "_meta"
    }

    public init(options: [ACPValue]? = nil, meta: [String: ACPValue]? = nil) {
        self.options = options
        self.meta = meta
    }
}

/// Session info update in an ACP v2 session.
public struct ACPSessionInfoUpdate: Codable, Sendable, Equatable {
    public var title: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case title
        case meta = "_meta"
    }

    public init(title: String? = nil, meta: [String: ACPValue]? = nil) {
        self.title = title
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
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var cost: ACPCost?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case totalTokens
        case cost
        case meta = "_meta"
    }

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cost: ACPCost? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.meta = meta
    }
}

/// Notice update in an ACP v2 session.
public struct ACPNotice: Codable, Sendable, Equatable {
    public var severity: String?
    public var title: String?
    public var message: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case severity
        case title
        case message
        case meta = "_meta"
    }

    public init(severity: String? = nil, title: String? = nil, message: String? = nil, meta: [String: ACPValue]? = nil) {
        self.severity = severity
        self.title = title
        self.message = message
        self.meta = meta
    }
}

/// Context compaction update in an ACP v2 session.
public struct ACPCompactionUpdate: Codable, Sendable, Equatable {
    public var compactionId: String
    public var status: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case compactionId
        case status
        case meta = "_meta"
    }

    public init(compactionId: String, status: String? = nil, meta: [String: ACPValue]? = nil) {
        self.compactionId = compactionId
        self.status = status
        self.meta = meta
    }
}

/// Context compaction summary chunk in an ACP v2 session.
public struct ACPCompactionSummaryChunk: Codable, Sendable, Equatable {
    public var compactionId: String
    public var summary: ACPContentBlock
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case compactionId
        case summary
        case meta = "_meta"
    }

    public init(compactionId: String, summary: ACPContentBlock, meta: [String: ACPValue]? = nil) {
        self.compactionId = compactionId
        self.summary = summary
        self.meta = meta
    }
}

/// Subagent update (unstable) in an ACP v2 session.
public struct ACPSubagentUpdate: Codable, Sendable, Equatable {
    public var subagentSessionId: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case subagentSessionId
        case meta = "_meta"
    }

    public init(subagentSessionId: String, meta: [String: ACPValue]? = nil) {
        self.subagentSessionId = subagentSessionId
        self.meta = meta
    }
}

/// Session message (unstable) in an ACP v2 session.
public struct ACPSessionMessage: Codable, Sendable, Equatable {
    public var messageId: String
    public var senderSessionId: String?
    public var recipientSessionId: String?
    public var content: [ACPContentBlock]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case messageId
        case senderSessionId
        case recipientSessionId
        case content
        case meta = "_meta"
    }

    public init(
        messageId: String,
        senderSessionId: String? = nil,
        recipientSessionId: String? = nil,
        content: [ACPContentBlock]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.messageId = messageId
        self.senderSessionId = senderSessionId
        self.recipientSessionId = recipientSessionId
        self.content = content
        self.meta = meta
    }
}

/// Session message chunk (unstable) in an ACP v2 session.
public struct ACPSessionMessageChunk: Codable, Sendable, Equatable {
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

/// Master ACP v2 SessionUpdate enumeration.
///
/// Fully extensible: unknown update kinds round-trip losslessly as `.other(sessionUpdate:fields:)`.
public enum ACPSessionUpdate: Codable, Sendable, Equatable {
    // 20 Stable variants
    case userMessageChunk(ACPContentChunk)
    case userMessage(ACPUserMessage)
    case agentMessageChunk(ACPContentChunk)
    case agentMessage(ACPAgentMessage)
    case agentThoughtChunk(ACPContentChunk)
    case agentThought(ACPAgentThought)
    case stateUpdate(ACPStateUpdate)
    case toolCall(ACPToolCallUpdate)
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
    // 4 Unstable variants
    case planRemoved(ACPPlanRemoved)
    case subagentUpdate(ACPSubagentUpdate)
    case sessionMessage(ACPSessionMessage)
    case sessionMessageChunk(ACPSessionMessageChunk)
    // Lossless extensibility
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
        case "tool_call":
            self = .toolCall(try single.decode(ACPToolCallUpdate.self))
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
        case "plan_removed":
            self = .planRemoved(try single.decode(ACPPlanRemoved.self))
        case "subagent_update":
            self = .subagentUpdate(try single.decode(ACPSubagentUpdate.self))
        case "session_message":
            self = .sessionMessage(try single.decode(ACPSessionMessage.self))
        case "session_message_chunk":
            self = .sessionMessageChunk(try single.decode(ACPSessionMessageChunk.self))
        default:
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "sessionUpdate")
            self = .other(sessionUpdate: kind, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        func encodeTagged<T: Encodable>(_ kind: String, value: T) throws {
            let valData = try JSONEncoder().encode(value)
            var dict = try JSONDecoder().decode([String: ACPValue].self, from: valData)
            dict["sessionUpdate"] = .string(kind)
            var container = encoder.singleValueContainer()
            try container.encode(dict)
        }

        switch self {
        case let .userMessageChunk(v): try encodeTagged("user_message_chunk", value: v)
        case let .userMessage(v): try encodeTagged("user_message", value: v)
        case let .agentMessageChunk(v): try encodeTagged("agent_message_chunk", value: v)
        case let .agentMessage(v): try encodeTagged("agent_message", value: v)
        case let .agentThoughtChunk(v): try encodeTagged("agent_thought_chunk", value: v)
        case let .agentThought(v): try encodeTagged("agent_thought", value: v)
        case let .stateUpdate(v): try encodeTagged("state_update", value: v)
        case let .toolCall(v): try encodeTagged("tool_call", value: v)
        case let .toolCallContentChunk(v): try encodeTagged("tool_call_content_chunk", value: v)
        case let .toolCallUpdate(v): try encodeTagged("tool_call_update", value: v)
        case let .terminalUpdate(v): try encodeTagged("terminal_update", value: v)
        case let .terminalOutputChunk(v): try encodeTagged("terminal_output_chunk", value: v)
        case let .planUpdate(v): try encodeTagged("plan_update", value: v)
        case let .availableCommandsUpdate(v): try encodeTagged("available_commands_update", value: v)
        case let .configOptionUpdate(v): try encodeTagged("config_option_update", value: v)
        case let .sessionInfoUpdate(v): try encodeTagged("session_info_update", value: v)
        case let .usageUpdate(v): try encodeTagged("usage_update", value: v)
        case let .notice(v): try encodeTagged("notice", value: v)
        case let .compactionUpdate(v): try encodeTagged("compaction_update", value: v)
        case let .compactionSummaryChunk(v): try encodeTagged("compaction_summary_chunk", value: v)
        case let .planRemoved(v): try encodeTagged("plan_removed", value: v)
        case let .subagentUpdate(v): try encodeTagged("subagent_update", value: v)
        case let .sessionMessage(v): try encodeTagged("session_message", value: v)
        case let .sessionMessageChunk(v): try encodeTagged("session_message_chunk", value: v)
        case let .other(kind, fields):
            var combined = fields
            combined["sessionUpdate"] = .string(kind)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }

    public var updateKind: String {
        switch self {
        case .userMessageChunk: return "user_message_chunk"
        case .userMessage: return "user_message"
        case .agentMessageChunk: return "agent_message_chunk"
        case .agentMessage: return "agent_message"
        case .agentThoughtChunk: return "agent_thought_chunk"
        case .agentThought: return "agent_thought"
        case .stateUpdate: return "state_update"
        case .toolCall: return "tool_call"
        case .toolCallContentChunk: return "tool_call_content_chunk"
        case .toolCallUpdate: return "tool_call_update"
        case .terminalUpdate: return "terminal_update"
        case .terminalOutputChunk: return "terminal_output_chunk"
        case .planUpdate: return "plan_update"
        case .availableCommandsUpdate: return "available_commands_update"
        case .configOptionUpdate: return "config_option_update"
        case .sessionInfoUpdate: return "session_info_update"
        case .usageUpdate: return "usage_update"
        case .notice: return "notice"
        case .compactionUpdate: return "compaction_update"
        case .compactionSummaryChunk: return "compaction_summary_chunk"
        case .planRemoved: return "plan_removed"
        case .subagentUpdate: return "subagent_update"
        case .sessionMessage: return "session_message"
        case .sessionMessageChunk: return "session_message_chunk"
        case let .other(kind, _): return kind
        }
    }
}
