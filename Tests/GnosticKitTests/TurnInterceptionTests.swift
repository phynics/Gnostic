// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Synchronization
import Testing

@testable import GnosticKit

private final class InterceptionRecorder: @unchecked Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ value: String) {
        storage.withLock { $0.append(value) }
    }

    var values: [String] {
        storage.withLock { $0 }
    }
}

private struct TaggingToolInterceptor: TurnToolIntercepting {
    let tag: String
    let recorder: InterceptionRecorder

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

private struct ShortCircuitToolInterceptor: TurnToolIntercepting {
    func intercept(
        _: TurnInterceptionToolCall,
        next _: @Sendable (TurnInterceptionToolCall) async throws -> TurnInterceptionToolResult
    ) async throws -> TurnInterceptionToolResult {
        .success("short-circuited")
    }
}

private struct AppendingModelInterceptor: TurnModelIntercepting {
    let text: String

    func interceptRequest(_ request: TurnInterceptionModelRequest) async throws -> TurnInterceptionModelRequest {
        var messages = request.messages
        messages.append(TurnInterceptionMessage(role: .system, content: text))
        return TurnInterceptionModelRequest(messages: messages, tier: request.tier)
    }
}

private struct RecordingModelInterceptor: TurnModelIntercepting {
    let recorder: InterceptionRecorder

    func observeResponse(_ chunk: TurnInterceptionModelChunk) async throws {
        recorder.append(chunk.content ?? "")
    }
}

private struct TaggingRoundInterceptor: TurnRoundIntercepting {
    let tag: String
    let recorder: InterceptionRecorder

    func intercept(
        _ round: TurnInterceptionRound,
        next: @Sendable () async throws -> Void
    ) async throws {
        recorder.append("\(tag):\(round.index):before")
        try await next()
        recorder.append("\(tag):\(round.index):after")
    }
}

/// Behavioral evidence for GNO-PLAT-P5 (#459): the kit owns backend-neutral
/// Turn interception points and a backend-neutral transcript view.
@Suite("Turn interception")
struct TurnInterceptionTests {
    @Test("tool interceptors nest outermost first and surround the wrapped call")
    func toolInterceptorsNest() async throws {
        let recorder = InterceptionRecorder()
        let pipeline = TurnInterceptionPipeline(toolInterceptors: [
            TaggingToolInterceptor(tag: "outer", recorder: recorder),
            TaggingToolInterceptor(tag: "inner", recorder: recorder),
        ])

        let result = try await pipeline.interceptTool(
            TurnInterceptionToolCall(name: "read", arguments: "{}")
        ) { _ in
            recorder.append("tool")
            return .success("content")
        }

        #expect(result == .success("content"))
        #expect(recorder.values == ["outer:before", "inner:before", "tool", "inner:after", "outer:after"])
    }

    @Test("a tool interceptor can answer without running the wrapped call")
    func toolInterceptorShortCircuits() async throws {
        let recorder = InterceptionRecorder()
        let pipeline = TurnInterceptionPipeline(toolInterceptors: [ShortCircuitToolInterceptor()])

        let result = try await pipeline.interceptTool(
            TurnInterceptionToolCall(name: "read", arguments: "{}")
        ) { _ in
            recorder.append("tool")
            return .success("content")
        }

        #expect(result == .success("short-circuited"))
        #expect(recorder.values.isEmpty)
    }

    @Test("model request hooks run in order and rewrite the request")
    func modelRequestHooksRunInOrder() async throws {
        let pipeline = TurnInterceptionPipeline(modelInterceptors: [
            AppendingModelInterceptor(text: "first"),
            AppendingModelInterceptor(text: "second"),
        ])

        let request = TurnInterceptionModelRequest(
            messages: [TurnInterceptionMessage(role: .user, content: "hi")],
            tier: .primary
        )
        let rewritten = try await pipeline.interceptRequest(request)

        #expect(rewritten.messages.map(\.content) == ["hi", "first", "second"])
    }

    @Test("response hooks observe every chunk in pipeline order")
    func responseHooksObserveChunks() async throws {
        let recorder = InterceptionRecorder()
        let pipeline = TurnInterceptionPipeline(modelInterceptors: [
            RecordingModelInterceptor(recorder: recorder),
            RecordingModelInterceptor(recorder: recorder),
        ])

        try await pipeline.observeResponse(TurnInterceptionModelChunk(content: "a"))
        try await pipeline.observeResponse(TurnInterceptionModelChunk(content: "b"))

        #expect(recorder.values == ["a", "a", "b", "b"])
    }

    @Test("pipeline composition preserves order and reports emptiness")
    func pipelineComposition() {
        let first = TurnInterceptionPipeline(modelInterceptors: [AppendingModelInterceptor(text: "a")])
        let second = TurnInterceptionPipeline(toolInterceptors: [ShortCircuitToolInterceptor()])

        #expect(first.isEmpty == false)
        #expect(TurnInterceptionPipeline.empty.isEmpty)

        let combined = first.appending(second)
        #expect(combined.modelInterceptors.count == 1)
        #expect(combined.toolInterceptors.count == 1)
    }

    @Test("round interceptors nest outermost first")
    func roundInterceptorsNest() async throws {
        let recorder = InterceptionRecorder()
        let pipeline = TurnInterceptionPipeline(roundInterceptors: [
            TaggingRoundInterceptor(tag: "outer", recorder: recorder),
            TaggingRoundInterceptor(tag: "inner", recorder: recorder),
        ])

        try await pipeline.interceptRound(TurnInterceptionRound(index: 0)) {
            recorder.append("round")
        }

        #expect(recorder.values == ["outer:0:before", "inner:0:before", "round", "inner:0:after", "outer:0:after"])
    }

    @Test("transcript folds assistant text, tool states, and a terminal outcome")
    func transcriptFoldsUpdates() {
        let updates = [
            AscendantTurnUpdate(sequence: 0, kind: .assistantText, text: "Hel"),
            AscendantTurnUpdate(sequence: 1, kind: .assistantText, text: "lo"),
            AscendantTurnUpdate(sequence: 2, kind: .assistantTextSnapshot, text: "Hello!"),
            AscendantTurnUpdate(
                sequence: 3,
                kind: .toolCall,
                toolState: AscendantToolState(toolCallID: "t1", title: "Read", status: .pending)
            ),
            AscendantTurnUpdate(
                sequence: 4,
                kind: .toolState,
                toolState: AscendantToolState(toolCallID: "t1", title: "Read", status: .completed, content: "ok")
            ),
            AscendantTurnUpdate(sequence: 5, kind: .completion, terminal: true),
        ]

        let transcript = TurnTranscript(updates: updates)

        #expect(transcript.assistantText == "Hello!")
        #expect(transcript.toolStates.count == 1)
        #expect(transcript.toolStates.first?.status == AscendantToolStatus.completed.rawValue)
        #expect(transcript.isTerminal)
        #expect(transcript.failed == false)
        #expect(transcript.terminalUpdate?.updateKind == .completion)
    }

    @Test("transcript reports a failed terminal outcome")
    func transcriptReportsFailure() {
        let transcript = TurnTranscript(updates: [
            AscendantTurnUpdate(sequence: 0, kind: .assistantText, text: "partial"),
            AscendantTurnUpdate(sequence: 1, kind: .error, terminal: true, reasonCode: "boom"),
        ])

        #expect(transcript.assistantText == "partial")
        #expect(transcript.isTerminal)
        #expect(transcript.failed)
        #expect(transcript.terminalUpdate?.updateKind == .error)
    }
}
