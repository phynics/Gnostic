// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit
import JSONSchema
import PKContracts
import PositronicKit
import Synchronization
import Testing

@testable import GnosticHost

private final class HostInterceptionRecorder: @unchecked Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ value: String) {
        storage.withLock { $0.append(value) }
    }

    var values: [String] {
        storage.withLock { $0 }
    }
}

private struct HostAppendingModelInterceptor: TurnModelIntercepting {
    let text: String

    func interceptRequest(_ request: TurnInterceptionModelRequest) async throws -> TurnInterceptionModelRequest {
        var messages = request.messages
        messages.append(TurnInterceptionMessage(role: .system, content: text))
        return TurnInterceptionModelRequest(messages: messages, tier: request.tier)
    }
}

private struct HostRecordingModelInterceptor: TurnModelIntercepting {
    let recorder: HostInterceptionRecorder

    func observeResponse(_ chunk: TurnInterceptionModelChunk) async throws {
        recorder.append(chunk.content ?? "")
    }
}

private struct HostTaggingToolInterceptor: TurnToolIntercepting {
    let tag: String
    let recorder: HostInterceptionRecorder

    func intercept(
        _ call: TurnInterceptionToolCall,
        next: @Sendable (TurnInterceptionToolCall) async throws -> TurnInterceptionToolResult
    ) async throws -> TurnInterceptionToolResult {
        recorder.append("\(tag):before")
        let result = try await next(call)
        recorder.append("\(tag):after")
        return result
    }
}

private struct HostShortCircuitToolInterceptor: TurnToolIntercepting {
    func intercept(
        _: TurnInterceptionToolCall,
        next _: @Sendable (TurnInterceptionToolCall) async throws -> TurnInterceptionToolResult
    ) async throws -> TurnInterceptionToolResult {
        .success("short-circuited")
    }
}

private struct FixturePKTool: PKTool {
    let result: ToolResult
    let recorder: HostInterceptionRecorder?

    let callName = "fixture"
    let name = "Fixture"
    let toolDescription = "Fixture tool."
    let requiresPermission = false

    var parametersSchema: Schema { ToolParameterSchema.object {}.schemaDefinition }

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        recorder?.append("tool")
        return result
    }
}

private actor RecordingLLMStreamClient: LLMStreamClient {
    nonisolated let configuration = LLMConfiguration()
    nonisolated let isConfigured = true

    private var recorded: [LLMMessage] = []
    private let chunks: [LLMStreamChunk]

    init(chunks: [LLMStreamChunk]) {
        self.chunks = chunks
    }

    func recordedMessages() -> [LLMMessage] { recorded }

    func structuredOutputAdapter(for _: ModelTier) async -> any StructuredOutputAdapter {
        DefaultStructuredOutputAdapter()
    }

    func generationStream(
        messages: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        recorded = messages
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

/// Behavioral evidence for GNO-PLAT-P5 (#459): the composition layer applies the
/// kit's Turn interception points to the Positronic model client and tool surface.
@Suite("Turn interception host adapters")
struct TurnInterceptionHostTests {
    @Test("model interception rewrites the request and observes the stream")
    func modelInterceptionRewritesAndObserves() async throws {
        let client = RecordingLLMStreamClient(chunks: [
            LLMStreamChunk(
                id: "1",
                model: "fixture",
                choices: [.init(index: 0, delta: .init(role: .assistant, content: "hi"))]
            ),
        ])
        let recorder = HostInterceptionRecorder()
        let pipeline = TurnInterceptionPipeline(modelInterceptors: [
            HostAppendingModelInterceptor(text: "injected"),
            HostRecordingModelInterceptor(recorder: recorder),
        ])
        let intercepting = InterceptingLLMStreamClient(underlying: client, pipeline: pipeline)

        let stream = await intercepting.generationStream(
            messages: [LLMMessage(role: .user, content: "q")],
            modelTier: .primary
        )
        var texts: [String] = []
        for try await chunk in stream {
            texts.append(chunk.choices.first?.delta.content ?? "")
        }

        let received = await client.recordedMessages()
        #expect(received.map(\.content) == ["q", "injected"])
        #expect(received.last?.role == .system)
        #expect(texts == ["hi"])
        #expect(recorder.values == ["hi"])
    }

    @Test("an untouched request preserves the original Positronic message")
    func untouchedRequestPreservesFidelity() async throws {
        let client = RecordingLLMStreamClient(chunks: [])
        let pipeline = TurnInterceptionPipeline(modelInterceptors: [
            HostRecordingModelInterceptor(recorder: HostInterceptionRecorder()),
        ])
        let intercepting = InterceptingLLMStreamClient(underlying: client, pipeline: pipeline)
        let message = LLMMessage(role: .assistant, content: "answer", reasoning: "because")

        _ = await intercepting.generationStream(messages: [message], modelTier: .primary)

        let received = await client.recordedMessages()
        #expect(received == [message])
    }

    @Test("tool interception nests and preserves the wrapped result")
    func toolInterceptionNestsAndPreservesResult() async throws {
        let recorder = HostInterceptionRecorder()
        let workspaceID = UUID()
        let tool = FixturePKTool(
            result: .success("out", workspaceID: workspaceID, workspaceRouting: .explicit),
            recorder: recorder
        )
        let pipeline = TurnInterceptionPipeline(toolInterceptors: [
            HostTaggingToolInterceptor(tag: "outer", recorder: recorder),
            HostTaggingToolInterceptor(tag: "inner", recorder: recorder),
        ])
        let wrapped = AnyTool(InterceptingTool(wrapped: AnyTool(tool), pipeline: pipeline))

        let result = try await wrapped.execute(parameters: [:])

        #expect(result.isSuccess)
        #expect(result.output == "out")
        #expect(result.workspaceID == workspaceID)
        #expect(result.workspaceRouting == WorkspaceToolRouting.explicit)
        #expect(recorder.values == ["outer:before", "inner:before", "tool", "inner:after", "outer:after"])
    }

    @Test("a tool interceptor can short-circuit the wrapped tool")
    func toolInterceptionShortCircuits() async throws {
        let recorder = HostInterceptionRecorder()
        let pipeline = TurnInterceptionPipeline(toolInterceptors: [HostShortCircuitToolInterceptor()])
        let wrapped = AnyTool(InterceptingTool(
            wrapped: AnyTool(FixturePKTool(result: .success("real"), recorder: recorder)),
            pipeline: pipeline
        ))

        let result = try await wrapped.execute(parameters: [:])

        #expect(result.output == "short-circuited")
        #expect(recorder.values.isEmpty)
    }

    @Test("a pipeline without tool interceptors leaves the tool surface untouched")
    func emptyPipelineLeavesToolsUntouched() {
        let tool = AnyTool(FixturePKTool(result: .success("out"), recorder: nil))
        let wrapped = TurnInterceptionMiddleware.wrap([tool], pipeline: .empty)

        #expect(wrapped.count == 1)
        #expect(wrapped[0].callName == tool.callName)
        #expect(wrapped[0].origin == tool.origin)
    }
}
