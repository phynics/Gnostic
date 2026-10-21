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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Client capabilities declared during ACP v2 initialization.
public struct ACPClientCapabilities: Codable, Sendable, Equatable {
    public var terminal: Bool?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case terminal
        case meta = "_meta"
    }

    public init(terminal: Bool? = nil, meta: [String: ACPValue]? = nil) {
        self.terminal = terminal
        self.meta = meta
    }
}

/// Prompt capabilities declared by an agent in ACP v2.
public struct ACPPromptCapabilities: Codable, Sendable, Equatable {
    public var image: Bool?
    public var audio: Bool?
    public var embeddedContext: Bool?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case image
        case audio
        case embeddedContext
        case meta = "_meta"
    }

    public init(image: Bool? = nil, audio: Bool? = nil, embeddedContext: Bool? = nil, meta: [String: ACPValue]? = nil) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
        self.meta = meta
    }
}

/// Agent session capabilities declared in ACP v2.
public struct ACPAgentSessionCapabilities: Codable, Sendable, Equatable {
    public var list: ACPValue?
    public var resume: ACPValue?
    public var close: ACPValue?
    public var additionalDirectories: Bool?
    public var mcp: [String]?
    public var meta: [String: ACPValue]?

    public var supportsResume: Bool {
        if let resume {
            return resume != .boolean(false) && resume != .null
        }
        return true
    }

    public var supportsClose: Bool {
        if let close {
            return close != .boolean(false) && close != .null
        }
        return true
    }

    public var supportsList: Bool {
        if let list {
            return list != .boolean(false) && list != .null
        }
        if resume != nil || close != nil {
            return false
        }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case list
        case resume
        case close
        case additionalDirectories
        case mcp
        case meta = "_meta"
    }

    public init(
        list: ACPValue? = nil,
        resume: ACPValue? = nil,
        close: ACPValue? = nil,
        additionalDirectories: Bool? = nil,
        mcp: [String]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.list = list
        self.resume = resume
        self.close = close
        self.additionalDirectories = additionalDirectories
        self.mcp = mcp
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.list = try container.decodeIfPresent(ACPValue.self, forKey: .list)
        self.resume = try container.decodeIfPresent(ACPValue.self, forKey: .resume)
        self.close = try container.decodeIfPresent(ACPValue.self, forKey: .close)
        self.additionalDirectories = try container.decodeIfPresent(Bool.self, forKey: .additionalDirectories)
        self.mcp = try container.decodeIfPresent([String].self, forKey: .mcp)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(list, forKey: .list)
        try container.encodeIfPresent(resume, forKey: .resume)
        try container.encodeIfPresent(close, forKey: .close)
        try container.encodeIfPresent(additionalDirectories, forKey: .additionalDirectories)
        try container.encodeIfPresent(mcp, forKey: .mcp)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Agent capabilities declared during ACP v2 initialization.
public struct ACPAgentCapabilities: Codable, Sendable, Equatable {
    public var session: ACPAgentSessionCapabilities?
    public var prompt: ACPPromptCapabilities?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case session
        case sessionCapabilities
        case prompt
        case meta = "_meta"
    }

    public init(
        session: ACPAgentSessionCapabilities? = nil,
        prompt: ACPPromptCapabilities? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.session = session
        self.prompt = prompt
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(ACPAgentSessionCapabilities.self, forKey: .session)
            ?? container.decodeIfPresent(ACPAgentSessionCapabilities.self, forKey: .sessionCapabilities)
        self.prompt = try container.decodeIfPresent(ACPPromptCapabilities.self, forKey: .prompt)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(session, forKey: .session)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(meta, forKey: .meta)
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
        case clientInfo
        case capabilities
        case clientCapabilities
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? ACPv2Protocol.protocolVersion
        self.info = try container.decodeIfPresent(ACPImplementation.self, forKey: .info)
            ?? container.decodeIfPresent(ACPImplementation.self, forKey: .clientInfo)
            ?? ACPImplementation(name: "unknown", version: "0.0.0")
        self.capabilities = try container.decodeIfPresent(ACPClientCapabilities.self, forKey: .capabilities)
            ?? container.decodeIfPresent(ACPClientCapabilities.self, forKey: .clientCapabilities)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(info, forKey: .info)
        try container.encode(info, forKey: .clientInfo)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(capabilities, forKey: .clientCapabilities)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Response returned by the `initialize` method in ACP v2.
public struct ACPInitializeResponse: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var info: ACPImplementation
    public var capabilities: ACPAgentCapabilities
    public var authMethods: [ACPValue]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case info
        case agentInfo
        case capabilities
        case agentCapabilities
        case authMethods
        case meta = "_meta"
    }

    public init(
        protocolVersion: Int = ACPv2Protocol.protocolVersion,
        info: ACPImplementation,
        capabilities: ACPAgentCapabilities,
        authMethods: [ACPValue]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.info = info
        self.capabilities = capabilities
        self.authMethods = authMethods
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? ACPv2Protocol.protocolVersion
        self.info = try container.decodeIfPresent(ACPImplementation.self, forKey: .info)
            ?? container.decodeIfPresent(ACPImplementation.self, forKey: .agentInfo)
            ?? ACPImplementation(name: "unknown", version: "0.0.0")
        self.capabilities = try container.decodeIfPresent(ACPAgentCapabilities.self, forKey: .capabilities)
            ?? container.decodeIfPresent(ACPAgentCapabilities.self, forKey: .agentCapabilities)
            ?? ACPAgentCapabilities()
        self.authMethods = try container.decodeIfPresent([ACPValue].self, forKey: .authMethods)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(info, forKey: .info)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(authMethods, forKey: .authMethods)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// MCP server configuration passed in session initialization.
public struct ACPMcpServer: Codable, Sendable, Equatable {
    public var name: String
    public var type: String
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    public var headers: [String: String]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case command
        case args
        case env
        case url
        case headers
        case meta = "_meta"
    }

    public init(
        name: String,
        type: String,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.name = name
        self.type = type
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.meta = meta
    }
}

/// Request parameters for the `session/new` method in ACP v2.
public struct ACPNewSessionRequest: Codable, Sendable, Equatable {
    public var cwd: String
    public var mcpServers: [ACPMcpServer]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case cwd
        case mcpServers
        case meta = "_meta"
    }

    public init(cwd: String, mcpServers: [ACPMcpServer]? = nil, meta: [String: ACPValue]? = nil) {
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.meta = meta
    }
}

/// Response returned by the `session/new` method in ACP v2.
public struct ACPNewSessionResponse: Codable, Sendable, Equatable {
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
public struct ACPPromptResponse: Codable, Sendable, Equatable {
    public var messageId: String?
    public var stopReason: ACPStopReason?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case messageId
        case stopReason
        case meta = "_meta"
    }

    public init(messageId: String? = nil, stopReason: ACPStopReason? = nil, meta: [String: ACPValue]? = nil) {
        self.messageId = messageId
        self.stopReason = stopReason
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
    public var mcpServers: [ACPMcpServer]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case mcpServers
        case meta = "_meta"
    }

    public init(sessionId: String, cwd: String, mcpServers: [ACPMcpServer]? = nil, meta: [String: ACPValue]? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.meta = meta
    }
}

/// Response returned by `session/resume` in ACP v2.
public struct ACPResumeSessionResponse: Codable, Sendable, Equatable {
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(meta: [String: ACPValue]? = nil) {
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
    public var title: String?
    public var cwd: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case title
        case cwd
        case meta = "_meta"
    }

    public init(sessionId: String, title: String? = nil, cwd: String? = nil, meta: [String: ACPValue]? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
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
    public var id: String
    public var title: String?
    public var kind: String?
    public var meta: [String: ACPValue]?

    public var optionId: String { id }

    enum CodingKeys: String, CodingKey {
        case id
        case optionId
        case title
        case kind
        case meta = "_meta"
    }

    public init(id: String, title: String? = nil, kind: String? = nil, meta: [String: ACPValue]? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let val = try container.decodeIfPresent(String.self, forKey: .id) {
            self.id = val
        } else if let val = try container.decodeIfPresent(String.self, forKey: .optionId) {
            self.id = val
        } else {
            self.id = ""
        }
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(meta, forKey: .meta)
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
}

/// Request parameters for `session/request_permission` in ACP v2.
public struct ACPRequestPermissionRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    public var toolCall: ACPToolCallUpdate?
    public var title: String?
    public var subject: ACPValue?
    public var options: [ACPPermissionOption]
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case toolCall
        case title
        case subject
        case options
        case meta = "_meta"
    }

    public init(
        sessionId: String,
        toolCall: ACPToolCallUpdate? = nil,
        title: String? = nil,
        subject: ACPValue? = nil,
        options: [ACPPermissionOption],
        meta: [String: ACPValue]? = nil
    ) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.title = title
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
