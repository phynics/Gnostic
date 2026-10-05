// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-030 (#505): the kit owns the metering seam,
/// counting calls and provider-reported tokens, marking calls whose provider
/// reported no usage, and costing a usage total at operator-supplied rates.
@Suite("Experiment metering")
struct ExperimentMeteringTests {
    @Test("metering counts calls and marks calls whose provider reported no usage")
    func meteringCountsUsage() async throws {
        let model = ExperimentMeteredModel(transport: UsageTransport(responses: [
            ExperimentGeneration(text: "one", promptTokens: 100, completionTokens: 10),
            ExperimentGeneration(text: "two", promptTokens: nil, completionTokens: nil),
            ExperimentGeneration(text: "  ", promptTokens: 5, completionTokens: 0),
        ]))
        _ = try await model.generate(prompt: "a", tier: .primary)
        _ = try await model.generate(prompt: "b", tier: .fast)
        await #expect(throws: ExperimentError.self) {
            _ = try await model.generate(prompt: "c", tier: .fast)
        }

        let usage = await model.usage
        #expect(usage == ExperimentUsage(calls: 3, promptTokens: 105, completionTokens: 10, callsWithoutUsage: 1))
        let pricing = ExperimentPricing(inputUSDPerMillionTokens: 3, outputUSDPerMillionTokens: 15, ratesDate: "2026-09-25")
        #expect(abs(pricing.cost(of: usage) - (105 * 3 + 10 * 15) / 1_000_000) < 1e-12)
    }

    @Test("usage totals add field by field")
    func usageAdds() {
        let total = ExperimentUsage(calls: 2, promptTokens: 100, completionTokens: 10)
            + ExperimentUsage(calls: 1, promptTokens: 50, completionTokens: 5, callsWithoutUsage: 1)
        #expect(total == ExperimentUsage(calls: 3, promptTokens: 150, completionTokens: 15, callsWithoutUsage: 1))
    }

    @Test("the kit defines its own model tier vocabulary")
    func modelTierVocabulary() {
        #expect(ExperimentModelTier.allCases.map(\.rawValue) == ["primary", "utility", "fast"])
    }
}

private actor UsageTransport: ExperimentModelTransport {
    private var responses: [ExperimentGeneration]

    init(responses: [ExperimentGeneration]) {
        self.responses = responses
    }

    func generate(prompt _: String, tier _: ExperimentModelTier) async throws -> ExperimentGeneration {
        responses.removeFirst()
    }
}
