// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticRLM
import PKContracts
import PositronicKit

/// One generation with the token usage its provider reported, if any.
struct RLMScenarioGeneration: Sendable, Equatable {
    let text: String
    let promptTokens: Int?
    let completionTokens: Int?
}

/// The single provider call the experiment meters. Production streams from a
/// configured `LLMStreamClient`; tests substitute a deterministic transport.
protocol RLMScenarioModelTransport: Sendable {
    func generate(prompt: String, tier: PositronicContributionModelTier) async throws -> RLMScenarioGeneration
}

/// Streams one user prompt, keeping the provider usage that
/// `PositronicContributionModelAdapter` discards.
struct RLMScenarioStreamTransport: RLMScenarioModelTransport {
    let client: any LLMStreamClient

    func generate(prompt: String, tier: PositronicContributionModelTier) async throws -> RLMScenarioGeneration {
        let modelTier: ModelTier = switch tier {
        case .primary: .primary
        case .utility: .utility
        case .fast: .fast
        }
        let stream = await client.generationStream(
            messages: [LLMMessage(role: .user, content: prompt)],
            modelTier: modelTier
        )
        var text = ""
        var usage: LLMTokenUsage?
        for try await chunk in stream {
            text += chunk.choices.first?.delta.content ?? ""
            if let reported = chunk.usage { usage = reported }
        }
        return RLMScenarioGeneration(
            text: text,
            promptTokens: usage?.promptTokens,
            completionTokens: usage?.completionTokens
        )
    }
}

/// Calls and provider-reported tokens for one model role in one run.
struct RLMScenarioUsage: Codable, Sendable, Equatable {
    var calls = 0
    var promptTokens = 0
    var completionTokens = 0
    /// Calls whose provider reported no usage. Non-zero means the token totals
    /// are a lower bound, and the run's cost is marked incomplete.
    var callsWithoutUsage = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            calls: lhs.calls + rhs.calls,
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            callsWithoutUsage: lhs.callsWithoutUsage + rhs.callsWithoutUsage
        )
    }
}

/// A contribution model service that records every call it forwards.
actor RLMScenarioMeteredModel: PositronicContributionModelService {
    private let transport: any RLMScenarioModelTransport
    private(set) var usage = RLMScenarioUsage()

    init(transport: any RLMScenarioModelTransport) {
        self.transport = transport
    }

    func generate(prompt: String, tier: PositronicContributionModelTier) async throws -> String {
        usage.calls += 1
        let generation = try await transport.generate(prompt: prompt, tier: tier)
        if let prompt = generation.promptTokens, let completion = generation.completionTokens {
            usage.promptTokens += prompt
            usage.completionTokens += completion
        } else {
            usage.callsWithoutUsage += 1
        }
        guard !generation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RLMFailure.rootModelFailed("the model returned an empty response")
        }
        return generation.text
    }
}

/// Operator-supplied provider rates, in US dollars per million tokens.
struct RLMScenarioPricing: Codable, Sendable, Equatable {
    let inputUSDPerMillionTokens: Double
    let outputUSDPerMillionTokens: Double
    /// The date the rates were in effect (manifest §1 cost accounting).
    let ratesDate: String

    func cost(of usage: RLMScenarioUsage) -> Double {
        (Double(usage.promptTokens) * inputUSDPerMillionTokens
            + Double(usage.completionTokens) * outputUSDPerMillionTokens) / 1_000_000
    }
}
