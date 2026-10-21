// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticKit
import JSONSchema
import PKContracts
import PositronicKit
import Synchronization

/// Runs the kit's Turn interception pipeline around a Positronic model client.
///
/// The pipeline carries only Gnostic-owned values, so this wrapper owns the
/// conversion between PositronicKit messages and chunks and the kit's neutral
/// views. A request hook may rewrite the conversation; the wrapper rebuilds the
/// PositronicKit messages only when the hook changed the neutral request, so an
/// untouched request keeps its multimodal parts and reasoning channel intact.
///
/// Response hooks observe every chunk. The wrapper always forwards the original
/// PositronicKit chunk, so observation never changes provider fidelity.
struct InterceptingLLMStreamClient: LLMStreamClient {
    let underlying: any LLMStreamClient
    let pipeline: TurnInterceptionPipeline

    var isConfigured: Bool {
        get async { await underlying.isConfigured }
    }

    var configuration: LLMConfiguration {
        get async { await underlying.configuration }
    }

    var readiness: ModelReadiness {
        get async { await underlying.readiness }
    }

    func structuredOutputAdapter(for modelTier: ModelTier) async -> any StructuredOutputAdapter {
        await underlying.structuredOutputAdapter(for: modelTier)
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities: Set<ResponseModality>,
        audioOutput: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        guard !pipeline.modelInterceptors.isEmpty else {
            return await underlying.generationStream(
                messages: messages,
                tools: tools,
                toolChoice: toolChoice,
                responseFormat: responseFormat,
                generationParameters: generationParameters,
                modelTier: modelTier,
                responseModalities: responseModalities,
                audioOutput: audioOutput
            )
        }

        let base = TurnInterceptionModelRequest(
            messages: messages.map(Self.neutral),
            tier: ExperimentModelTier(modelTier)
        )
        let rewritten: TurnInterceptionModelRequest
        do {
            rewritten = try await pipeline.interceptRequest(base)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let resolvedMessages = rewritten.messages == base.messages ? messages : rewritten.messages.map(\.llmMessage)
        let upstream = await underlying.generationStream(
            messages: resolvedMessages,
            tools: tools,
            toolChoice: toolChoice,
            responseFormat: responseFormat,
            generationParameters: generationParameters,
            modelTier: modelTier,
            responseModalities: responseModalities,
            audioOutput: audioOutput
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream {
                        try await pipeline.observeResponse(Self.neutral(chunk))
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func neutral(_ message: LLMMessage) -> TurnInterceptionMessage {
        TurnInterceptionMessage(
            role: TurnInterceptionMessage.Role(rawValue: message.role.rawValue) ?? .user,
            content: message.content,
            name: message.name,
            toolCallID: message.toolCallID,
            toolCalls: (message.toolCalls ?? []).map {
                TurnInterceptionToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments)
            }
        )
    }

    private static func neutral(_ chunk: LLMStreamChunk) -> TurnInterceptionModelChunk {
        let content = chunk.choices.compactMap { $0.delta.content }.joined()
        let reasoning = chunk.choices.compactMap { $0.delta.reasoning }.joined()
        let deltas = chunk.choices.flatMap { choice in
            (choice.delta.toolCalls ?? []).map { delta in
                TurnInterceptionToolCallDelta(
                    index: delta.index,
                    id: delta.id,
                    name: delta.function?.name,
                    arguments: delta.function?.arguments
                )
            }
        }
        return TurnInterceptionModelChunk(
            content: content.isEmpty ? nil : content,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            toolCalls: deltas,
            usage: chunk.usage.map {
                TurnInterceptionUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
            },
            finishReason: chunk.choices.compactMap(\.finishReason).first
        )
    }
}

private extension TurnInterceptionMessage {
    /// Rebuilds a PositronicKit message from the neutral view.
    ///
    /// The rebuild carries text only. The wrapper calls it only when a request
    /// hook changed the neutral request, so an untouched message is never
    /// rebuilt and keeps its multimodal parts and reasoning channel.
    var llmMessage: LLMMessage {
        LLMMessage(
            role: LLMMessage.Role(rawValue: role.rawValue) ?? .user,
            content: content,
            name: name,
            toolCallID: toolCallID,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls.map {
                LLMToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            }
        )
    }
}

public extension ExperimentModelTier {
    /// Maps a PositronicKit model tier onto the kit tier.
    init(_ tier: ModelTier) {
        self = switch tier {
        case .primary: .primary
        case .utility: .utility
        case .fast: .fast
        }
    }
}

/// Wraps one Positronic tool and runs the kit's tool interceptor chain.
///
/// The wrapper delegates every descriptive member to the wrapped tool, so the
/// model sees the same name, schema, permission policy, and side-effect class.
/// Only ``execute(parameters:)`` runs the interceptor chain. When the chain
/// passes the wrapped result through unchanged, the original ``ToolResult`` is
/// returned, so workspace routing metadata is preserved.
struct InterceptingTool: PKTool {
    let wrapped: AnyTool
    let pipeline: TurnInterceptionPipeline

    var callName: String { wrapped.callName }
    var identity: ToolReference { wrapped.identity }
    var name: String { wrapped.name }
    var toolDescription: String { wrapped.toolDescription }
    var requiresPermission: Bool { wrapped.requiresPermission }
    var sideEffects: ToolSideEffects { wrapped.sideEffects }
    var usageExample: String? { wrapped.usageExample }
    var parametersSchema: Schema { wrapped.parametersSchema }

    func requiresPermission(for parameters: [String: AnyCodable]) -> Bool {
        wrapped.requiresPermission(for: parameters)
    }

    func canExecute() async -> Bool {
        await wrapped.canExecute()
    }

    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard !pipeline.toolInterceptors.isEmpty else {
            return try await wrapped.execute(parameters: parameters)
        }
        let call = TurnInterceptionToolCall(
            name: wrapped.callName,
            arguments: Self.arguments(parameters),
            origin: wrapped.origin.promptLabel
        )
        let box = Mutex<ToolResult?>(nil)
        let intercepted = try await pipeline.interceptTool(call) { _ in
            let result = try await wrapped.execute(parameters: parameters)
            box.withLock { $0 = result }
            return TurnInterceptionToolResult(
                isSuccess: result.isSuccess,
                output: result.output,
                error: result.error
            )
        }
        if let original = box.withLock({ $0 }), intercepted == Self.neutral(original) {
            return original
        }
        return ToolResult(isSuccess: intercepted.isSuccess, output: intercepted.output, error: intercepted.error)
    }

    func summarize(parameters: [String: AnyCodable], result: ToolResult) -> String {
        wrapped.summarize(parameters: parameters, result: result)
    }

    private static func neutral(_ result: ToolResult) -> TurnInterceptionToolResult {
        TurnInterceptionToolResult(isSuccess: result.isSuccess, output: result.output, error: result.error)
    }

    private static func arguments(_ parameters: [String: AnyCodable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(parameters) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds the Positronic tool surface for one Turn interception pipeline.
enum TurnInterceptionMiddleware {
    /// Wraps every tool with the pipeline's tool interceptors.
    ///
    /// A pipeline with no tool interceptor returns the original array so the
    /// adapter keeps its exact tool identities and origins.
    static func wrap(_ tools: [AnyTool], pipeline: TurnInterceptionPipeline) -> [AnyTool] {
        guard !pipeline.toolInterceptors.isEmpty else { return tools }
        return tools.map { AnyTool(InterceptingTool(wrapped: $0, pipeline: pipeline), origin: $0.origin) }
    }
}
