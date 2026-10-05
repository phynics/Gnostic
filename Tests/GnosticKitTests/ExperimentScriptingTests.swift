// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-034 (#509): a deterministic scripted model
/// completes a run with zero provider contact, and a recording transport
/// captures every call.
@Suite("Experiment scripting")
struct ExperimentScriptingTests {
    @Test("a scripted transport replays its script in order and then defaults")
    func scriptedReplays() async throws {
        let transport = ScriptedExperimentModelTransport(
            script: [.text("first", promptTokens: 10, completionTokens: 1)],
            defaultResponse: "rest"
        )
        let metered = ExperimentMeteredModel(transport: transport)
        #expect(try await metered.generate(prompt: "a", tier: .primary) == "first")
        #expect(try await metered.generate(prompt: "b", tier: .fast) == "rest")
        let usage = await metered.usage
        #expect(usage == ExperimentUsage(calls: 2, promptTokens: 10, completionTokens: 1))
    }

    @Test("an exhausted script fails")
    func exhaustedScriptFails() async {
        let transport = ScriptedExperimentModelTransport(script: [])
        await #expect(throws: ExperimentError.self) {
            _ = try await transport.generate(prompt: "a", tier: .primary)
        }
    }

    @Test("a recording transport captures prompts, tiers, text, and usage")
    func recordingCaptures() async throws {
        let transport = RecordingExperimentModelTransport(
            wrapping: ScriptedExperimentModelTransport(defaultResponse: "answer")
        )
        let metered = ExperimentMeteredModel(transport: transport)
        _ = try await metered.generate(prompt: "hello", tier: .utility)

        let calls = await transport.calls
        #expect(calls.count == 1)
        #expect(calls.first?.prompt == "hello")
        #expect(calls.first?.tier == .utility)
        #expect(calls.first?.text == "answer")
    }
}
