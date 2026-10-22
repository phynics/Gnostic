// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Implementation info identifying an ACP client or agent implementation.
public struct ACPImplementation: Codable, Sendable, Equatable {
    public var name: String
    public var title: String?
    public var version: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case version
        case meta = "_meta"
    }

    public init(name: String, title: String? = nil, version: String, meta: [String: ACPValue]? = nil) {
        self.name = name
        self.title = title
        self.version = version
        self.meta = meta
    }
}

/// Presence-only capability object. Supplying `{}` advertises support.
public struct ACPPresenceCapability: Codable, Sendable, Equatable {
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(meta: [String: ACPValue]? = nil) {
        self.meta = meta
    }
}

/// Client authentication capabilities.
public struct ACPAuthCapabilities: Codable, Sendable, Equatable {
    public var terminal: ACPPresenceCapability?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case terminal
        case meta = "_meta"
    }

    public init(terminal: ACPPresenceCapability? = nil, meta: [String: ACPValue]? = nil) {
        self.terminal = terminal
        self.meta = meta
    }
}

/// Client elicitation capabilities.
public struct ACPElicitationCapabilities: Codable, Sendable, Equatable {
    public var form: ACPPresenceCapability?
    public var url: ACPPresenceCapability?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case form
        case url
        case meta = "_meta"
    }

    public init(
        form: ACPPresenceCapability? = nil,
        url: ACPPresenceCapability? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.form = form
        self.url = url
        self.meta = meta
    }
}

/// Client capabilities declared during ACP v2 initialization.
public struct ACPClientCapabilities: Codable, Sendable, Equatable {
    public var auth: ACPAuthCapabilities?
    public var elicitation: ACPElicitationCapabilities?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case auth
        case elicitation
        case meta = "_meta"
    }

    public init(
        auth: ACPAuthCapabilities? = nil,
        elicitation: ACPElicitationCapabilities? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.auth = auth
        self.elicitation = elicitation
        self.meta = meta
    }
}

/// Prompt capabilities declared by an agent in ACP v2.
public struct ACPPromptCapabilities: Codable, Sendable, Equatable {
    public var image: ACPPresenceCapability?
    public var audio: ACPPresenceCapability?
    public var embeddedContext: ACPPresenceCapability?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case image
        case audio
        case embeddedContext
        case meta = "_meta"
    }

    public init(
        image: ACPPresenceCapability? = nil,
        audio: ACPPresenceCapability? = nil,
        embeddedContext: ACPPresenceCapability? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
        self.meta = meta
    }
}

/// MCP transport capabilities declared by an agent.
public struct ACPMcpCapabilities: Codable, Sendable, Equatable {
    public var stdio: ACPPresenceCapability?
    public var http: ACPPresenceCapability?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case stdio
        case http
        case meta = "_meta"
    }

    public init(
        stdio: ACPPresenceCapability? = nil,
        http: ACPPresenceCapability? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.stdio = stdio
        self.http = http
        self.meta = meta
    }
}

/// Agent session capabilities declared in ACP v2.
///
/// An empty capability object advertises the baseline session methods
/// (`new`, `list`, `resume`, `close`, `prompt`, `cancel`, `update`).
public struct ACPAgentSessionCapabilities: Codable, Sendable, Equatable {
    public var prompt: ACPPromptCapabilities?
    public var mcp: ACPMcpCapabilities?
    public var delete: ACPPresenceCapability?
    public var additionalDirectories: ACPPresenceCapability?
    public var meta: [String: ACPValue]?

    /// Baseline session methods are available whenever this object is present.
    public var supportsResume: Bool { true }
    public var supportsClose: Bool { true }
    public var supportsList: Bool { true }

    enum CodingKeys: String, CodingKey {
        case prompt
        case mcp
        case delete
        case additionalDirectories
        case meta = "_meta"
    }

    public init(
        prompt: ACPPromptCapabilities? = nil,
        mcp: ACPMcpCapabilities? = nil,
        delete: ACPPresenceCapability? = nil,
        additionalDirectories: ACPPresenceCapability? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.prompt = prompt
        self.mcp = mcp
        self.delete = delete
        self.additionalDirectories = additionalDirectories
        self.meta = meta
    }
}

/// Agent authentication extension capabilities.
public struct ACPAgentAuthCapabilities: Codable, Sendable, Equatable {
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(meta: [String: ACPValue]? = nil) {
        self.meta = meta
    }
}

/// Agent capabilities declared during ACP v2 initialization.
public struct ACPAgentCapabilities: Codable, Sendable, Equatable {
    public var session: ACPAgentSessionCapabilities?
    public var auth: ACPAgentAuthCapabilities?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case session
        case auth
        case meta = "_meta"
    }

    public init(
        session: ACPAgentSessionCapabilities? = nil,
        auth: ACPAgentAuthCapabilities? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.session = session
        self.auth = auth
        self.meta = meta
    }
}

/// Request parameters for the `initialize` method in ACP v2.
public struct ACPInitializeRequest: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var info: ACPImplementation
    public var capabilities: ACPClientCapabilities?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case info
        case capabilities
        case meta = "_meta"
    }

    public init(
        protocolVersion: Int = ACPv2Protocol.protocolVersion,
        info: ACPImplementation,
        capabilities: ACPClientCapabilities? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.info = info
        self.capabilities = capabilities
        self.meta = meta
    }
}

/// Response returned by the `initialize` method in ACP v2.
public struct ACPInitializeResponse: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var info: ACPImplementation
    public var capabilities: ACPAgentCapabilities?
    public var authMethods: [ACPValue]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case info
        case capabilities
        case authMethods
        case meta = "_meta"
    }

    public init(
        protocolVersion: Int = ACPv2Protocol.protocolVersion,
        info: ACPImplementation,
        capabilities: ACPAgentCapabilities? = nil,
        authMethods: [ACPValue]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.info = info
        self.capabilities = capabilities
        self.authMethods = authMethods
        self.meta = meta
    }
}

/// Environment variable entry.
public struct ACPEnvVariable: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case name
        case value
        case meta = "_meta"
    }

    public init(name: String, value: String, meta: [String: ACPValue]? = nil) {
        self.name = name
        self.value = value
        self.meta = meta
    }
}

/// HTTP header for an HTTP MCP server.
public struct ACPMcpHTTPHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case name
        case value
        case meta = "_meta"
    }

    public init(name: String, value: String, meta: [String: ACPValue]? = nil) {
        self.name = name
        self.value = value
        self.meta = meta
    }
}

/// MCP server configuration passed in session initialization.
public enum ACPMcpServer: Codable, Sendable, Equatable {
    case stdio(name: String, command: String, args: [String]?, env: [ACPEnvVariable]?, meta: [String: ACPValue]?)
    case http(name: String, url: String, headers: [ACPMcpHTTPHeader]?, meta: [String: ACPValue]?)
    case other(type: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case command
        case args
        case env
        case url
        case headers
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "stdio":
            let name = try container.decode(String.self, forKey: .name)
            let command = try container.decode(String.self, forKey: .command)
            let args = try container.decodeIfPresent([String].self, forKey: .args)
            let env = try container.decodeIfPresent([ACPEnvVariable].self, forKey: .env)
            let meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
            self = .stdio(name: name, command: command, args: args, env: env, meta: meta)
        case "http":
            let name = try container.decode(String.self, forKey: .name)
            let url = try container.decode(String.self, forKey: .url)
            let headers = try container.decodeIfPresent([ACPMcpHTTPHeader].self, forKey: .headers)
            let meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
            self = .http(name: name, url: url, headers: headers, meta: meta)
        default:
            let single = try decoder.singleValueContainer()
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "type")
            self = .other(type: type, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .stdio(name, command, args, env, meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("stdio", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(args, forKey: .args)
            try container.encodeIfPresent(env, forKey: .env)
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .http(name, url, headers, meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("http", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(headers, forKey: .headers)
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .other(type, fields):
            var combined = fields
            combined["type"] = .string(type)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }
}

/// Request parameters for the `session/new` method in ACP v2.
public struct ACPNewSessionRequest: Codable, Sendable, Equatable {
    public var cwd: String
    public var mcpServers: [ACPMcpServer]?
    public var additionalDirectories: [String]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case cwd
        case mcpServers
        case additionalDirectories
        case meta = "_meta"
    }

    public init(
        cwd: String,
        mcpServers: [ACPMcpServer]? = nil,
        additionalDirectories: [String]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.additionalDirectories = additionalDirectories
        self.meta = meta
    }
}

/// Response returned by the `session/new` method in ACP v2.
public struct ACPNewSessionResponse: Codable, Sendable, Equatable {
    public var sessionId: String
    public var configOptions: [ACPValue]?
    public var availableCommands: [ACPValue]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case configOptions
        case availableCommands
        case meta = "_meta"
    }

    public init(
        sessionId: String,
        configOptions: [ACPValue]? = nil,
        availableCommands: [ACPValue]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.sessionId = sessionId
        self.configOptions = configOptions
        self.availableCommands = availableCommands
        self.meta = meta
    }
}

/// Request parameters for the `session/prompt` method in ACP v2.
public struct ACPPromptRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var prompt: [ACPContentBlock]
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case prompt
        case meta = "_meta"
    }

    public init(sessionId: String, prompt: [ACPContentBlock], meta: [String: ACPValue]? = nil) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.meta = meta
    }
}

/// Response returned by the `session/prompt` method in ACP v2.
///
/// The response acknowledges insertion only. Completion arrives as an idle
/// `state_update` session update.
public struct ACPPromptResponse: Codable, Sendable, Equatable {
    public var messageId: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case messageId
        case meta = "_meta"
    }

    public init(messageId: String, meta: [String: ACPValue]? = nil) {
        self.messageId = messageId
        self.meta = meta
    }
}

/// Notification parameters for `session/cancel` in ACP v2.
public struct ACPCancelSessionNotification: Codable, Sendable, Equatable {
    public var sessionId: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case meta = "_meta"
    }

    public init(sessionId: String, meta: [String: ACPValue]? = nil) {
        self.sessionId = sessionId
        self.meta = meta
    }
}

/// Notification parameters for `$/cancel_request` in ACP v2.
public struct ACPCancelRequestNotification: Codable, Sendable, Equatable {
    public var requestId: ACPRequestId
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case requestId
        case meta = "_meta"
    }

    public init(requestId: ACPRequestId, meta: [String: ACPValue]? = nil) {
        self.requestId = requestId
        self.meta = meta
    }
}

/// Request parameters for `session/resume` in ACP v2.
public struct ACPResumeSessionRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var additionalDirectories: [String]?
    public var mcpServers: [ACPMcpServer]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case additionalDirectories
        case mcpServers
        case meta = "_meta"
    }

    public init(
        sessionId: String,
        cwd: String,
        additionalDirectories: [String]? = nil,
        mcpServers: [ACPMcpServer]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.meta = meta
    }
}

/// Response returned by `session/resume` in ACP v2.
public struct ACPResumeSessionResponse: Codable, Sendable, Equatable {
    public var configOptions: [ACPValue]?
    public var availableCommands: [ACPValue]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case configOptions
        case availableCommands
        case meta = "_meta"
    }

    public init(
        configOptions: [ACPValue]? = nil,
        availableCommands: [ACPValue]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.configOptions = configOptions
        self.availableCommands = availableCommands
        self.meta = meta
    }
}

/// Request parameters for `session/close` in ACP v2.
public struct ACPCloseSessionRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case meta = "_meta"
    }

    public init(sessionId: String, meta: [String: ACPValue]? = nil) {
        self.sessionId = sessionId
        self.meta = meta
    }
}

/// Response returned by `session/close` in ACP v2.
public struct ACPCloseSessionResponse: Codable, Sendable, Equatable {
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(meta: [String: ACPValue]? = nil) {
        self.meta = meta
    }
}

/// Session summary info reported by `session/list`.
public struct ACPSessionInfo: Codable, Sendable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var additionalDirectories: [String]?
    public var title: String?
    public var updatedAt: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case additionalDirectories
        case title
        case updatedAt
        case meta = "_meta"
    }

    public init(
        sessionId: String,
        cwd: String,
        additionalDirectories: [String]? = nil,
        title: String? = nil,
        updatedAt: String? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.title = title
        self.updatedAt = updatedAt
        self.meta = meta
    }
}

/// Request parameters for `session/list` in ACP v2.
public struct ACPListSessionsRequest: Codable, Sendable, Equatable {
    public var cwd: String?
    public var cursor: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case cwd
        case cursor
        case meta = "_meta"
    }

    public init(cwd: String? = nil, cursor: String? = nil, meta: [String: ACPValue]? = nil) {
        self.cwd = cwd
        self.cursor = cursor
        self.meta = meta
    }
}

/// Response returned by `session/list` in ACP v2.
public struct ACPListSessionsResponse: Codable, Sendable, Equatable {
    public var sessions: [ACPSessionInfo]
    public var nextCursor: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessions
        case nextCursor
        case meta = "_meta"
    }

    public init(sessions: [ACPSessionInfo], nextCursor: String? = nil, meta: [String: ACPValue]? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.meta = meta
    }
}

/// Permission option provided in `session/request_permission`.
public struct ACPPermissionOption: Codable, Sendable, Equatable {
    public var optionId: String
    public var name: String
    public var kind: String
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case optionId
        case name
        case kind
        case meta = "_meta"
    }

    public init(optionId: String, name: String, kind: String, meta: [String: ACPValue]? = nil) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
        self.meta = meta
    }
}

/// Outcome of a permission request in ACP v2.
public struct ACPRequestPermissionOutcome: Codable, Sendable, Equatable {
    public var outcome: String
    public var optionId: String?
    public var meta: [String: ACPValue]?

    public static let cancelled = ACPRequestPermissionOutcome(outcome: "cancelled")
    public static func selected(_ optionId: String) -> ACPRequestPermissionOutcome {
        ACPRequestPermissionOutcome(outcome: "selected", optionId: optionId)
    }

    enum CodingKeys: String, CodingKey {
        case outcome
        case optionId
        case meta = "_meta"
    }

    public init(outcome: String, optionId: String? = nil, meta: [String: ACPValue]? = nil) {
        self.outcome = outcome
        self.optionId = optionId
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try container.decode(String.self, forKey: .outcome)
        self.optionId = try container.decodeIfPresent(String.self, forKey: .optionId)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
        if outcome == "selected", optionId == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .optionId,
                in: container,
                debugDescription: "A selected permission outcome requires 'optionId'"
            )
        }
    }
}

/// The operation requiring permission in ACP v2.
public enum ACPRequestPermissionSubject: Codable, Sendable, Equatable {
    case toolCall(ACPToolCallUpdate)
    case command(command: String, cwd: String, toolCallId: String?, terminalId: String?, meta: [String: ACPValue]?)
    case other(type: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case type
        case toolCall
        case command
        case cwd
        case toolCallId
        case terminalId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch type {
        case "tool_call":
            self = .toolCall(try container.decode(ACPToolCallUpdate.self, forKey: .toolCall))
        case "command":
            self = .command(
                command: try container.decode(String.self, forKey: .command),
                cwd: try container.decode(String.self, forKey: .cwd),
                toolCallId: try container.decodeIfPresent(String.self, forKey: .toolCallId),
                terminalId: try container.decodeIfPresent(String.self, forKey: .terminalId),
                meta: try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
            )
        default:
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "type")
            self = .other(type: type, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .toolCall(toolCall):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("tool_call", forKey: .type)
            try container.encode(toolCall, forKey: .toolCall)
        case let .command(command, cwd, toolCallId, terminalId, meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("command", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(cwd, forKey: .cwd)
            try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
            try container.encodeIfPresent(terminalId, forKey: .terminalId)
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .other(type, fields):
            var combined = fields
            combined["type"] = .string(type)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }
}

/// Request parameters for `session/request_permission` in ACP v2.
public struct ACPRequestPermissionRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var title: String
    public var description: String?
    public var subject: ACPRequestPermissionSubject?
    public var options: [ACPPermissionOption]
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case title
        case description
        case subject
        case options
        case meta = "_meta"
    }

    public init(
        sessionId: String,
        title: String,
        description: String? = nil,
        subject: ACPRequestPermissionSubject? = nil,
        options: [ACPPermissionOption],
        meta: [String: ACPValue]? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.description = description
        self.subject = subject
        self.options = options
        self.meta = meta
    }
}

/// Response returned for `session/request_permission` in ACP v2.
public struct ACPRequestPermissionResponse: Codable, Sendable, Equatable {
    public var outcome: ACPRequestPermissionOutcome
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case outcome
        case meta = "_meta"
    }

    public init(outcome: ACPRequestPermissionOutcome, meta: [String: ACPValue]? = nil) {
        self.outcome = outcome
        self.meta = meta
    }
}

/// Notification sent for `session/update` in ACP v2.
public struct ACPSessionNotification: Codable, Sendable, Equatable {
    public var sessionId: String
    public var update: ACPSessionUpdate
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case update
        case meta = "_meta"
    }

    public init(sessionId: String, update: ACPSessionUpdate, meta: [String: ACPValue]? = nil) {
        self.sessionId = sessionId
        self.update = update
        self.meta = meta
    }
}
