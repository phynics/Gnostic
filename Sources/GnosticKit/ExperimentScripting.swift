// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// One scripted response in a deterministic transport.
public struct ExperimentScriptedResponse: Sendable, Equatable {
    /// What the scripted transport returns for one call.
    public enum Outcome: Sendable, Equatable {
        /// Return the text, optionally without a failure.
        case text(String)
        /// Throw the given failure description.
        case failure(String)
    }

    /// The outcome.
    public let outcome: Outcome
    /// The prompt tokens the transport reports.
    public let promptTokens: Int?
    /// The completion tokens the transport reports.
    public let completionTokens: Int?

    /// Creates one scripted response.
    public init(outcome: Outcome, promptTokens: Int? = 0, completionTokens: Int? = 0) {
        self.outcome = outcome
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    /// A text response.
    public static func text(_ value: String, promptTokens: Int? = 0, completionTokens: Int? = 0) -> Self {
        Self(outcome: .text(value), promptTokens: promptTokens, completionTokens: completionTokens)
    }
}

/// A deterministic transport that replays a fixed script.
///
/// It never touches a provider, so a harness gate can run in `make verify`.
/// After the script is exhausted it returns `defaultResponse`, or fails when
/// none is set.
public actor ScriptedExperimentModelTransport: ExperimentModelTransport {
    private let script: [ExperimentScriptedResponse]
    private let defaultResponse: String?
    private var index = 0

    /// Creates a transport that replays `script`.
    public init(script: [ExperimentScriptedResponse], defaultResponse: String? = nil) {
        self.script = script
        self.defaultResponse = defaultResponse
    }

    /// Creates a transport that always returns `defaultResponse`.
    public init(defaultResponse: String) {
        self.script = []
        self.defaultResponse = defaultResponse
    }

    public func generate(prompt _: String, tier _: ExperimentModelTier) async throws -> ExperimentGeneration {
        if index < script.count {
            let response = script[index]
            index += 1
            switch response.outcome {
            case let .text(text):
                return ExperimentGeneration(
                    text: text,
                    promptTokens: response.promptTokens,
                    completionTokens: response.completionTokens
                )
            case let .failure(reason):
                throw ExperimentError.scriptFailure(reason)
            }
        }
        guard let defaultResponse else {
            throw ExperimentError.scriptExhausted
        }
        return ExperimentGeneration(text: defaultResponse, promptTokens: 0, completionTokens: 0)
    }
}

/// One recorded model call.
public struct ExperimentModelCall: Codable, Sendable, Equatable {
    /// The prompt the transport received.
    public let prompt: String
    /// The tier requested.
    public let tier: ExperimentModelTier
    /// The text the transport returned.
    public let text: String
    /// The prompt tokens reported.
    public let promptTokens: Int?
    /// The completion tokens reported.
    public let completionTokens: Int?

    /// Creates one recorded call.
    public init(prompt: String, tier: ExperimentModelTier, text: String, promptTokens: Int?, completionTokens: Int?) {
        self.prompt = prompt
        self.tier = tier
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// A transport that records every call it forwards.
///
/// It sits at the kit's neutral model seam, so it records a scripted run, a
/// replay, or a live run alike and carries no backend type.
public actor RecordingExperimentModelTransport: ExperimentModelTransport {
    private let wrapped: any ExperimentModelTransport
    /// The calls recorded so far.
    public private(set) var calls: [ExperimentModelCall] = []

    /// Creates a recording transport over another transport.
    public init(wrapping wrapped: any ExperimentModelTransport) {
        self.wrapped = wrapped
    }

    public func generate(prompt: String, tier: ExperimentModelTier) async throws -> ExperimentGeneration {
        let generation = try await wrapped.generate(prompt: prompt, tier: tier)
        calls.append(ExperimentModelCall(
            prompt: prompt,
            tier: tier,
            text: generation.text,
            promptTokens: generation.promptTokens,
            completionTokens: generation.completionTokens
        ))
        return generation
    }
}
