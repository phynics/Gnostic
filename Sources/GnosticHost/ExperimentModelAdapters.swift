// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticKit
import PKContracts
import PositronicKit
import GnosticPositronicBackend

/// Bridges a kit model service to the Positronic contribution model seam.
///
/// The Positronic contribution hook and its native client stay inside this
/// composition target, so `GnosticKit` never names a backend type. When the
/// Positronic backend leaves `GnosticCore` in P7 (#460), this adapter moves with
/// the backend and the kit is untouched.
public struct PositronicContributionModelServiceAdapter: PositronicContributionModelService {
    let service: any ExperimentModelService

    /// Creates an adapter over one kit model service.
    public init(service: any ExperimentModelService) {
        self.service = service
    }

    public func generate(prompt: String, tier: PositronicContributionModelTier) async throws -> String {
        try await service.generate(prompt: prompt, tier: ExperimentModelTier(tier))
    }
}

public extension ExperimentModelTier {
    /// Maps a Positronic contribution tier onto the kit tier.
    init(_ tier: PositronicContributionModelTier) {
        self = switch tier {
        case .primary: .primary
        case .utility: .utility
        case .fast: .fast
        }
    }
}

/// Streams one prompt through a configured `LLMStreamClient`, keeping the
/// provider usage the Positronic adapter would otherwise discard.
///
/// This is the production transport for a live experiment run. It lives in the
/// composition target because it carries a PositronicKit value.
public struct LLMStreamClientExperimentTransport: ExperimentModelTransport {
    let client: any LLMStreamClient

    /// Creates a transport over one configured client.
    public init(client: any LLMStreamClient) {
        self.client = client
    }

    public func generate(prompt: String, tier: ExperimentModelTier) async throws -> ExperimentGeneration {
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
        return ExperimentGeneration(
            text: text,
            promptTokens: usage?.promptTokens,
            completionTokens: usage?.completionTokens
        )
    }
}
