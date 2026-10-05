// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The model tier an experiment asks for.
///
/// The kit owns this vocabulary so it never names a backend-specific tier type.
/// A backend adapter maps its own tiers onto these cases.
public enum ExperimentModelTier: String, Sendable, Equatable, CaseIterable {
    case primary
    case utility
    case fast
}

/// The narrow model boundary the kit meters, scripts, and records.
///
/// The protocol carries only Gnostic-owned values. A backend adapter bridges it
/// to that backend's model client, so the kit never depends on a backend
/// implementation.
public protocol ExperimentModelService: Sendable {
    /// Generates one response for one prompt.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to send.
    ///   - tier: The model tier to use.
    /// - Returns: The generated text.
    /// - Throws: A backend or experiment failure. The kit never swallows it.
    func generate(prompt: String, tier: ExperimentModelTier) async throws -> String
}

/// One generation with the token usage its provider reported, if any.
public struct ExperimentGeneration: Sendable, Equatable {
    /// The generated text.
    public let text: String
    /// Prompt tokens the provider reported, or `nil` when it reported none.
    public let promptTokens: Int?
    /// Completion tokens the provider reported, or `nil` when it reported none.
    public let completionTokens: Int?

    /// Creates one generation record.
    public init(text: String, promptTokens: Int?, completionTokens: Int?) {
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// The single provider call an experiment meters.
///
/// A production transport streams from a configured client; a scripted or
/// recording transport substitutes it for a deterministic run.
public protocol ExperimentModelTransport: Sendable {
    func generate(prompt: String, tier: ExperimentModelTier) async throws -> ExperimentGeneration
}

/// Structured kit failures.
public enum ExperimentError: Error, Equatable, CustomStringConvertible {
    /// The model returned text that is empty after trimming.
    case emptyModelResponse
    /// A scripted transport ran out of responses.
    case scriptExhausted
    /// The frozen case set changed from its approved digest.
    case caseSetChanged(expected: String, actual: String)
    /// The frozen case set could not be parsed.
    case malformedCaseSet(String)
    /// A pilot artifact is missing or cannot authorise the comparison.
    case missingPilot(String)
    /// The resumed artifact belongs to a different round.
    case manifestMismatch(String)
    /// A rating named an unknown or incomplete run.
    case unknownRating(String)
    /// A rating was outside the accepted range.
    case ratingOutOfRange(id: String, score: Int)

    public var description: String {
        switch self {
        case .emptyModelResponse:
            "the model returned an empty response"
        case .scriptExhausted:
            "the scripted model script is exhausted"
        case let .caseSetChanged(expected, actual):
            "the frozen case set changed (expected SHA-256 \(expected), found \(actual)); a new case set needs a new manifest version"
        case let .malformedCaseSet(reason):
            "the frozen case set could not be parsed: \(reason)"
        case let .missingPilot(reason):
            "the comparison needs an accepted pilot: \(reason)"
        case let .manifestMismatch(reason):
            "the existing artifact belongs to a different round and cannot be resumed: \(reason)"
        case let .unknownRating(id):
            "score for unknown or incomplete run \(id)"
        case let .ratingOutOfRange(id, score):
            "score \(score) for \(id) is outside the accepted range"
        }
    }
}

/// Calls and provider-reported tokens for one model role in one run.
public struct ExperimentUsage: Codable, Sendable, Equatable {
    /// The number of generation calls.
    public var calls: Int
    /// Prompt tokens the provider reported across all calls.
    public var promptTokens: Int
    /// Completion tokens the provider reported across all calls.
    public var completionTokens: Int
    /// Calls whose provider reported no usage.
    ///
    /// Non-zero means the token totals are a lower bound, and the run's cost is
    /// marked incomplete.
    public var callsWithoutUsage: Int

    /// Creates a usage total.
    public init(calls: Int = 0, promptTokens: Int = 0, completionTokens: Int = 0, callsWithoutUsage: Int = 0) {
        self.calls = calls
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.callsWithoutUsage = callsWithoutUsage
    }

    /// Adds two usage totals.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            calls: lhs.calls + rhs.calls,
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            callsWithoutUsage: lhs.callsWithoutUsage + rhs.callsWithoutUsage
        )
    }
}

/// A model service that records every call it forwards.
///
/// The metered model is aware of provider-reported usage: a call whose provider
/// reports none is counted but does not add tokens, and it marks the total as a
/// lower bound.
public actor ExperimentMeteredModel: ExperimentModelService {
    private let transport: any ExperimentModelTransport
    /// The usage recorded so far.
    public private(set) var usage = ExperimentUsage()

    /// Creates a metered model over one transport.
    public init(transport: any ExperimentModelTransport) {
        self.transport = transport
    }

    public func generate(prompt: String, tier: ExperimentModelTier) async throws -> String {
        usage.calls += 1
        let generation = try await transport.generate(prompt: prompt, tier: tier)
        if let prompt = generation.promptTokens, let completion = generation.completionTokens {
            usage.promptTokens += prompt
            usage.completionTokens += completion
        } else {
            usage.callsWithoutUsage += 1
        }
        guard !generation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExperimentError.emptyModelResponse
        }
        return generation.text
    }
}

/// Operator-supplied provider rates, in US dollars per million tokens.
public struct ExperimentPricing: Codable, Sendable, Equatable {
    /// Input (prompt) price, USD per million tokens.
    public let inputUSDPerMillionTokens: Double
    /// Output (completion) price, USD per million tokens.
    public let outputUSDPerMillionTokens: Double
    /// The date the rates were in effect.
    public let ratesDate: String

    /// Creates one rate card.
    public init(inputUSDPerMillionTokens: Double, outputUSDPerMillionTokens: Double, ratesDate: String) {
        self.inputUSDPerMillionTokens = inputUSDPerMillionTokens
        self.outputUSDPerMillionTokens = outputUSDPerMillionTokens
        self.ratesDate = ratesDate
    }

    /// The cost of one usage total at these rates.
    public func cost(of usage: ExperimentUsage) -> Double {
        (Double(usage.promptTokens) * inputUSDPerMillionTokens
            + Double(usage.completionTokens) * outputUSDPerMillionTokens) / 1_000_000
    }
}
