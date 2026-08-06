// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import JSONSchema
import PKShared
import PKUtilities
import PositronicKit
import Testing

@testable import GnosticCLI

/// A deterministic, credential-free LanguageModel for chat tests.
///
/// The stub emits tool calls for a fixed script and then final assistant text,
/// mirroring the runner fixture's `workspace_echo` narrative without any LLM.
final class StubLanguageModel: LanguageModel, @unchecked Sendable {
    private let counter = CallCounter()
    private let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    private actor CallCounter {
        private var count = 0
        func nextCall() -> Int {
            count += 1
            return count
        }
    }

    var isConfigured: Bool {
        get async { true }
    }

    var configuration: LLMConfiguration {
        get async { .init(activeProvider: .openAI, providers: [:]) }
    }

    func chatStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        if shouldFail {
            return failingStream()
        }
        let isFirstCall = await counter.nextCall() == 1

        if isFirstCall {
            // Emit a tool call to workspace_echo.
            let args = #"{"value":"network"}"#
            let chunk = LLMStreamChunk(
                id: "c1",
                model: "stub",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(
                        role: .assistant,
                        toolCalls: [LLMToolCallDelta(
                            index: 0,
                            id: "call_1",
                            function: LLMToolCallDeltaFunction(name: "workspace_echo", arguments: args)
                        )]
                    ),
                    finishReason: "tool_calls"
                )]
            )
            return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
        }

        // Second call: final text after the tool result.
        let text = "Echo received: network"
        let chunk = LLMStreamChunk(
            id: "c2",
            model: "stub",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(content: text),
                finishReason: "stop"
            )]
        )
        return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
    }

    private func failingStream() -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: StubError.failure)
        }
    }

    enum StubError: Error { case failure }

    // LLMConfigStore
    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}

    // LLMUtilityClient
    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(_: String, responseFormat _: LLMResponseFormat?, generationParameters _: GenerationParameters?, useUtilityModel _: Bool) async throws -> String { "ok" }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { "stub" }
    func evaluateRecallPerformance(transcript _: String, recalledMemories _: [Memory]) async throws -> [String: Double] { [:] }
    func fetchAvailableModels() async throws -> [String]? { nil }
}

@Suite("Chat REPL")
struct ChatREPLTests {
    private func makeSessionAndREPL(
        shouldFail: Bool = false,
        lines: [String],
        approval: (@Sendable () -> Bool)? = nil
    ) async throws -> (ChatSession, ChatREPL) {
        let kit = PositronicKit(languageModel: StubLanguageModel(shouldFail: shouldFail))
        let timeline = try await kit.timelineManager.createTimeline()
        let session = ChatSession(kit: kit, tools: [], timelineID: timeline.id)
        let iterator = LineIterator(lines: lines)
        let sink = OutputSink()
        let repl = ChatREPL(
            session: session,
            timelineID: timeline.id,
            approval: StubApprovalPolicy(decision: approval ?? { true }),
            readLine: { iterator.next() },
            writeOutput: { sink.append($0) }
        )
        return (session, repl)
    }

    @Test("a scripted session runs a conversation and prints the final text") @MainActor
    func scriptedConversation() async throws {
        let kit = PositronicKit(languageModel: StubLanguageModel())
        let timeline = try await kit.timelineManager.createTimeline()
        let session = ChatSession(kit: kit, tools: [], timelineID: timeline.id)
        let iterator = LineIterator(lines: ["hello", "/quit"])
        let sink = OutputSink()
        let repl = ChatREPL(
            session: session,
            timelineID: timeline.id,
            approval: StubApprovalPolicy(decision: { true }),
            readLine: { iterator.next() },
            writeOutput: { sink.append($0) }
        )
        await repl.run()
        let output = sink.lines
        // The stub's second call emits the final assistant text; the tool call
        // round-trip happened in between. Output must contain assistant text and bye.
        #expect(output.contains(where: { $0.contains("Echo received: network") }))
        #expect(output.last == "bye.")
    }

    @Test("failed turns keep the loop alive") @MainActor
    func failedTurnKeepsLoopAlive() async throws {
        let kit = PositronicKit(languageModel: StubLanguageModel(shouldFail: true))
        let timeline = try await kit.timelineManager.createTimeline()
        let session = ChatSession(kit: kit, tools: [], timelineID: timeline.id)
        let iterator = LineIterator(lines: ["hello", "hello again", "/quit"])
        let sink = OutputSink()
        let repl = ChatREPL(
            session: session,
            timelineID: timeline.id,
            approval: StubApprovalPolicy(decision: { true }),
            readLine: { iterator.next() },
            writeOutput: { sink.append($0) }
        )
        await repl.run()
        let output = sink.lines
        // Two failing turns each surface an Error line, then /quit prints bye.
        let errorLines = output.filter { $0.hasPrefix("Error:") }
        #expect(errorLines.count >= 1)
        #expect(output.last == "bye.")
    }

    @Test("slash commands dispatch") @MainActor
    func slashCommands() async throws {
        let kit = PositronicKit(languageModel: StubLanguageModel())
        let timeline = try await kit.timelineManager.createTimeline()
        let session = ChatSession(kit: kit, tools: [], timelineID: timeline.id)
        let iterator = LineIterator(lines: ["/timeline", "/quit"])
        let sink = OutputSink()
        let repl = ChatREPL(
            session: session,
            timelineID: timeline.id,
            approval: StubApprovalPolicy(decision: { true }),
            readLine: { iterator.next() },
            writeOutput: { sink.append($0) }
        )
        await repl.run()
        let output = sink.lines
        #expect(output.contains { $0.hasPrefix("timeline:") })
        #expect(output.last == "bye.")
    }

    @Test("ChatSession drives a tool call then the final text through PositronicKit") @MainActor
    func sessionDrivesToolCallThenFinalText() async throws {
        let kit = PositronicKit(languageModel: StubLanguageModel())
        let timeline = try await kit.timelineManager.createTimeline()
        // A fixture workspace_echo tool, mirroring the runner fixture route.
        let echo = EchoTool()
        let session = ChatSession(kit: kit, tools: [echo], timelineID: timeline.id)

        let result = try await session.run(line: "echo network")

        guard case .text = result else {
            Issue.record("expected text result, got \(result)")
            return
        }
        // The stub's first call emitted the tool call; the second emitted the
        // final assistant text. The tool executed in between.
        #expect(await echo.invocations() == 1)
    }

    @Test("a workspace_echo tool executes through the turn loop") @MainActor
    func workspaceEchoExecutes() async throws {
        let kit = PositronicKit(languageModel: StubLanguageModel())
        let timeline = try await kit.timelineManager.createTimeline()
        let echo = EchoTool()
        let session = ChatSession(kit: kit, tools: [echo], timelineID: timeline.id)

        let result = try await session.run(line: "echo network")

        guard case .text = result else {
            Issue.record("expected text result, got \(result)")
            return
        }
        #expect(await echo.invocations() == 1)
        #expect(await echo.lastValue() == "network")
    }
}

/// A thread-safe line iterator for scripted sessions.
final class LineIterator: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]
    init(lines: [String]) { self.lines = lines }
    func next() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }
}

/// A fixture `workspace_echo` tool that records its invocations.
final class EchoTool: Tool, @unchecked Sendable {
    private let state = EchoState()
    func invocations() async -> Int { await state.count }
    func lastValue() async -> String? { await state.value }

    private actor EchoState {
        var count = 0
        var value: String?
        func record(_ value: String) {
            count += 1
            self.value = value
        }
    }

    let callName = "workspace_echo"
    let name = "Workspace echo"
    let description = "Echoes fixture input."
    let requiresPermission = false
    let sideEffects: ToolSideEffects = .none
    var parametersSchema: JSONSchema.Schema { JSONSchema.Schema([:]) }

    func canExecute() async -> Bool { true }
    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        let value = parameters["value"]?.value as? String ?? ""
        await state.record(value)
        return .success(value)
    }
}

/// A deterministic approval gate.
struct StubApprovalPolicy: ToolApprovalPolicy {
    let decision: @Sendable () -> Bool
    func requestApproval(tool _: AnyTool, arguments _: [String: AnyCodable]) async -> ToolApprovalDecision {
        decision() ? .approve : .deny
    }
}

/// An append-only output accumulator for REPL output assertions.
final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }
}
@Suite("Chat provider factory")
struct ChatProviderFactoryTests {
    @Test("an OpenAI-compatible configuration resolves a real client (no clientNotResolved)")
    func openAICompatibleResolvesClient() async throws {
        var configuration = LLMConfiguration(activeProvider: .openAICompatible)
        var provider = ProviderConfiguration.makeDefault(for: .openAICompatible)
        provider.endpoint = "https://api.code.umans.ai"
        provider.apiKey = "sk-test"
        provider.modelName = "umans-deepseek-v4-flash-0731-lab"
        configuration.providers[.openAICompatible] = provider

        let service = LLMService.configured(from: configuration)
        let llm = try #require(service as? LLMService)

        // The provider's client factory must resolve a non-nil client. isReady
        // requires configuration.isValid AND a resolved primary client.
        #expect(await llm.isConfigured)
        #expect(await llm.isReady)
        #expect(await llm.client() != nil)
    }
}
