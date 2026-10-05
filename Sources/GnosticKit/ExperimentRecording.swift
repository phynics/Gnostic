// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One tool call a harness made: the tool name and its arguments.
public struct ExperimentToolInvocation: Sendable, Equatable {
    /// The tool's callable name.
    public let name: String
    /// The arguments, as the harness passed them.
    public let arguments: String

    /// Creates one tool invocation.
    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

/// The narrow tool boundary the kit records.
///
/// The protocol carries only Gnostic-owned values, so a host bridges its own
/// tool executor onto it and the kit never names a backend or workspace type.
public protocol ExperimentToolTransport: Sendable {
    /// Executes one tool call and returns its result.
    func invoke(_ invocation: ExperimentToolInvocation) async throws -> String
}

/// A model transport that records every call it forwards into a tape.
///
/// Recording is opt-in: a run records only when its owner builds a
/// ``ExperimentTraceRecorder`` and wraps a transport with it. The tape holds
/// payloads only because this wrapper is present.
public actor TracingExperimentModelTransport: ExperimentModelTransport {
    private let wrapped: any ExperimentModelTransport
    private let recorder: ExperimentTraceRecorder

    /// Creates a recording transport over another transport.
    public init(wrapping wrapped: any ExperimentModelTransport, recorder: ExperimentTraceRecorder) {
        self.wrapped = wrapped
        self.recorder = recorder
    }

    public func generate(prompt: String, tier: ExperimentModelTier) async throws -> ExperimentGeneration {
        await recorder.recordModelRequest(prompt: prompt, tier: tier)
        do {
            let generation = try await wrapped.generate(prompt: prompt, tier: tier)
            await recorder.recordModelResponse(
                text: generation.text,
                promptTokens: generation.promptTokens,
                completionTokens: generation.completionTokens
            )
            return generation
        } catch {
            // A failure is a recorded fact, not a silent gap. The error still
            // propagates unchanged.
            await recorder.recordModelResponse(text: "", promptTokens: nil, completionTokens: nil, failed: true)
            throw error
        }
    }
}

/// A tool executor that records every call it forwards into a tape.
///
/// It is the tool half of the opt-in recording seam. A thrown tool failure is
/// recorded before it propagates.
public actor TracingExperimentToolExecutor {
    private let wrapped: any ExperimentToolTransport
    private let recorder: ExperimentTraceRecorder

    /// Creates a recording executor over another executor.
    public init(wrapping wrapped: any ExperimentToolTransport, recorder: ExperimentTraceRecorder) {
        self.wrapped = wrapped
        self.recorder = recorder
    }

    /// Executes one tool call, recording the call and its result.
    public func invoke(_ invocation: ExperimentToolInvocation) async throws -> String {
        await recorder.recordToolCall(name: invocation.name, arguments: invocation.arguments)
        do {
            let result = try await wrapped.invoke(invocation)
            await recorder.recordToolResult(name: invocation.name, result: result)
            return result
        } catch {
            await recorder.recordToolResult(name: invocation.name, result: "\(error)", failed: true)
            throw error
        }
    }
}
