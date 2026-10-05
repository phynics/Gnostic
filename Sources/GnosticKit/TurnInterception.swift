// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// A backend-neutral view of one message in a model request.
///
/// A module that intercepts model calls reads and rewrites this value instead
/// of a provider-specific message type. A backend adapter maps its own message
/// type onto this one, so the kit never depends on a backend.
public struct TurnInterceptionMessage: Sendable, Equatable {
    /// The declared message roles the kit understands.
    public enum Role: String, Sendable, Equatable, CaseIterable {
        case system
        case developer
        case user
        case assistant
        case tool
    }

    /// The message role.
    public let role: Role
    /// The rendered text content.
    public let content: String
    /// An optional participant name.
    public let name: String?
    /// The tool call this message answers, when the role is `tool`.
    public let toolCallID: String?
    /// The tool calls an assistant message requested.
    public let toolCalls: [TurnInterceptionToolCallRecord]

    /// Creates one neutral message.
    public init(
        role: Role,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [TurnInterceptionToolCallRecord] = []
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}

/// One tool call an assistant message requested, in neutral form.
public struct TurnInterceptionToolCallRecord: Sendable, Equatable {
    /// The provider call identifier.
    public let id: String
    /// The tool name.
    public let name: String
    /// The JSON arguments string.
    public let arguments: String

    /// Creates one recorded tool call.
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The neutral view of one model request a module may rewrite.
public struct TurnInterceptionModelRequest: Sendable, Equatable {
    /// The conversation sent to the model.
    public let messages: [TurnInterceptionMessage]
    /// The requested model tier.
    public let tier: ExperimentModelTier

    /// Creates one neutral model request.
    public init(messages: [TurnInterceptionMessage], tier: ExperimentModelTier) {
        self.messages = messages
        self.tier = tier
    }
}

/// Token usage a provider reported for one chunk.
public struct TurnInterceptionUsage: Sendable, Equatable {
    /// Prompt tokens the provider reported, or `nil` when it reported none.
    public let promptTokens: Int?
    /// Completion tokens the provider reported, or `nil` when it reported none.
    public let completionTokens: Int?

    /// Creates one usage record.
    public init(promptTokens: Int?, completionTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// One incremental tool call fragment in a streamed model chunk.
public struct TurnInterceptionToolCallDelta: Sendable, Equatable {
    /// The parallel call index, when the provider supplies one.
    public let index: Int?
    /// The call identifier, present on the fragment that starts the call.
    public let id: String?
    /// The tool name, present on the fragment that starts the call.
    public let name: String?
    /// The incremental JSON arguments fragment.
    public let arguments: String?

    /// Creates one tool call fragment.
    public init(index: Int? = nil, id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The neutral view of one streamed model chunk a module may observe.
public struct TurnInterceptionModelChunk: Sendable, Equatable {
    /// Incremental text content.
    public let content: String?
    /// Incremental reasoning content.
    public let reasoning: String?
    /// Incremental tool call fragments.
    public let toolCalls: [TurnInterceptionToolCallDelta]
    /// Provider-reported usage, when the provider reports it.
    public let usage: TurnInterceptionUsage?
    /// The finish reason, present on the final chunk.
    public let finishReason: String?

    /// Creates one neutral chunk.
    public init(
        content: String? = nil,
        reasoning: String? = nil,
        toolCalls: [TurnInterceptionToolCallDelta] = [],
        usage: TurnInterceptionUsage? = nil,
        finishReason: String? = nil
    ) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
    }
}

/// Intercepts model calls inside a Turn.
///
/// A module rewrites the request by returning a new ``TurnInterceptionModelRequest``
/// and observes each streamed chunk by returning from ``observeResponse(_:)``.
/// Both hooks default to pass-through, so a module implements only what it needs.
public protocol TurnModelIntercepting: Sendable {
    /// Rewrites one model request before the backend sends it.
    ///
    /// Return `request` unchanged to leave the call untouched. Returning a new
    /// request replaces the messages the backend sends.
    func interceptRequest(_ request: TurnInterceptionModelRequest) async throws -> TurnInterceptionModelRequest

    /// Observes one streamed chunk after the backend produced it.
    func observeResponse(_ chunk: TurnInterceptionModelChunk) async throws
}

public extension TurnModelIntercepting {
    func interceptRequest(_ request: TurnInterceptionModelRequest) async throws -> TurnInterceptionModelRequest { request }

    func observeResponse(_: TurnInterceptionModelChunk) async throws {}
}

/// A neutral tool call a module may intercept.
public struct TurnInterceptionToolCall: Sendable, Equatable {
    /// The provider call identifier, when the provider supplies one.
    public let callID: String?
    /// The tool name.
    public let name: String
    /// The JSON arguments string.
    public let arguments: String
    /// The origin label the backend attached to the tool, when it has one.
    public let origin: String?

    /// Creates one neutral tool call.
    public init(callID: String? = nil, name: String, arguments: String, origin: String? = nil) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.origin = origin
    }
}

/// The neutral result of one tool call.
public struct TurnInterceptionToolResult: Sendable, Equatable {
    /// Whether the call succeeded.
    public let isSuccess: Bool
    /// The produced output.
    public let output: String
    /// The failure description, when the call failed.
    public let error: String?

    /// Creates one neutral tool result.
    public init(isSuccess: Bool, output: String, error: String? = nil) {
        self.isSuccess = isSuccess
        self.output = output
        self.error = error
    }

    /// Creates a successful result.
    public static func success(_ output: String) -> TurnInterceptionToolResult {
        TurnInterceptionToolResult(isSuccess: true, output: output)
    }

    /// Creates a failed result.
    public static func failure(_ error: String) -> TurnInterceptionToolResult {
        TurnInterceptionToolResult(isSuccess: false, output: "", error: error)
    }
}

/// Intercepts tool calls inside a Turn.
///
/// A module receives the call, may observe or rewrite it, and decides whether
/// to run the wrapped call by calling `next`. It may also answer without
/// running `next`, which short-circuits the tool.
public protocol TurnToolIntercepting: Sendable {
    /// Intercepts one tool call.
    ///
    /// - Parameters:
    ///   - call: The tool call the model requested.
    ///   - next: Runs the wrapped tool call and returns its result.
    /// - Returns: The result the runtime records for this call.
    /// - Throws: A module or tool failure.
    func intercept(
        _ call: TurnInterceptionToolCall,
        next: @Sendable (TurnInterceptionToolCall) async throws -> TurnInterceptionToolResult
    ) async throws -> TurnInterceptionToolResult
}

/// One model round inside a Turn.
public struct TurnInterceptionRound: Sendable, Equatable {
    /// The zero-based round index.
    public let index: Int
    /// The configured round ceiling, when the backend exposes one.
    public let ceiling: Int?

    /// Creates one round description.
    public init(index: Int, ceiling: Int? = nil) {
        self.index = index
        self.ceiling = ceiling
    }
}

/// Intercepts model rounds inside a Turn.
///
/// A module wraps one round by running `next`. The round hook exists so a
/// backend that exposes round boundaries can offer them without each module
/// requesting a new backend API. A backend that does not expose rounds leaves
/// this hook unwired.
public protocol TurnRoundIntercepting: Sendable {
    /// Intercepts one model round.
    ///
    /// - Parameters:
    ///   - round: The round the backend is about to run.
    ///   - next: Runs the wrapped round.
    /// - Throws: A module or backend failure.
    func intercept(
        _ round: TurnInterceptionRound,
        next: @Sendable () async throws -> Void
    ) async throws
}

/// The ordered set of interceptions a Turn applies.
///
/// The composition layer builds one pipeline per Ascendant from the selected
/// modules. Model request hooks run in order; response hooks run in order for
/// each chunk. Tool and round hooks nest in order, so the first interceptor is
/// the outermost.
public struct TurnInterceptionPipeline: Sendable {
    /// Model interceptors, outermost first.
    public let modelInterceptors: [any TurnModelIntercepting]
    /// Tool interceptors, outermost first.
    public let toolInterceptors: [any TurnToolIntercepting]
    /// Round interceptors, outermost first.
    public let roundInterceptors: [any TurnRoundIntercepting]

    /// Creates a pipeline from ordered interceptors.
    public init(
        modelInterceptors: [any TurnModelIntercepting] = [],
        toolInterceptors: [any TurnToolIntercepting] = [],
        roundInterceptors: [any TurnRoundIntercepting] = []
    ) {
        self.modelInterceptors = modelInterceptors
        self.toolInterceptors = toolInterceptors
        self.roundInterceptors = roundInterceptors
    }

    /// A pipeline that changes nothing.
    public static let empty = TurnInterceptionPipeline()

    /// Whether the pipeline carries no interceptor.
    public var isEmpty: Bool {
        modelInterceptors.isEmpty && toolInterceptors.isEmpty && roundInterceptors.isEmpty
    }

    /// Returns a pipeline that runs this pipeline and then `other`.
    public func appending(_ other: TurnInterceptionPipeline) -> TurnInterceptionPipeline {
        TurnInterceptionPipeline(
            modelInterceptors: modelInterceptors + other.modelInterceptors,
            toolInterceptors: toolInterceptors + other.toolInterceptors,
            roundInterceptors: roundInterceptors + other.roundInterceptors
        )
    }

    /// Runs every model request hook in order and returns the final request.
    public func interceptRequest(_ request: TurnInterceptionModelRequest) async throws -> TurnInterceptionModelRequest {
        var current = request
        for interceptor in modelInterceptors {
            current = try await interceptor.interceptRequest(current)
        }
        return current
    }

    /// Runs every model response hook in order for one chunk.
    public func observeResponse(_ chunk: TurnInterceptionModelChunk) async throws {
        for interceptor in modelInterceptors {
            try await interceptor.observeResponse(chunk)
        }
    }

    /// Runs one tool call through every tool interceptor, outermost first.
    public func interceptTool(
        _ call: TurnInterceptionToolCall,
        next: @escaping @Sendable (TurnInterceptionToolCall) async throws -> TurnInterceptionToolResult
    ) async throws -> TurnInterceptionToolResult {
        var handler = next
        for interceptor in toolInterceptors.reversed() {
            let wrapped = handler
            handler = { call in
                try await interceptor.intercept(call, next: wrapped)
            }
        }
        return try await handler(call)
    }

    /// Runs one round through every round interceptor, outermost first.
    public func interceptRound(
        _ round: TurnInterceptionRound,
        next: @escaping @Sendable () async throws -> Void
    ) async throws {
        var handler = next
        for interceptor in roundInterceptors.reversed() {
            let wrapped = handler
            handler = {
                try await interceptor.intercept(round, next: wrapped)
            }
        }
        try await handler()
    }
}
