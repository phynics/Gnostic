// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticKit
import Testing
import GnosticPositronicBackend

@testable import GnosticPositronicContext

@Suite("Offline context hypothesis gate")
struct ContextGateTests {
    @Test("all five strategies are scored with deterministic assertions")
    func allFiveArmsAreScored() async throws {
        let result = try await ContextGate().run()
        #expect(result.arms.map(\.arm) == ContextGateArm.allCases)
        let expectedChecks = ContextFixtureTranscript.cases
            .flatMap { ContextFixtureTranscript.checksByCaseID[$0.id] ?? [] }
            .count
        for arm in result.arms {
            #expect(arm.checksTotal == expectedChecks)
            #expect(arm.recall > 0)
            #expect(arm.recallByObligation.isEmpty == false)
        }
    }

    @Test("curation retains every obligation the baselines lose")
    func curationBeatsBaselines() async throws {
        let result = try await ContextGate().run()
        let raw = try #require(result.arms.first { $0.arm == .rawHistory })
        let best = try #require(ContextGate.bestCuration(result.arms))
        #expect(best.recall >= raw.recall)
        #expect(result.bestCurationArm == best.arm)
    }

    @Test("the offline gate recommends SIMPLIFY: flat carry pays off, the hierarchy does not")
    func decisionIsSimplify() async throws {
        let result = try await ContextGate().run()
        #expect(result.decision == .simplify)
        #expect(!result.rationale.isEmpty)
        let flat = try #require(result.arms.first { $0.arm == .incrementalFlat })
        let cover = try #require(result.arms.first { $0.arm == .hierarchicalCover })
        #expect(flat.recall == cover.recall)
        #expect(flat.projectionCharacters == cover.projectionCharacters)
    }

    @Test("the gate is deterministic")
    func gateIsDeterministic() async throws {
        let first = try await ContextGate().run()
        let second = try await ContextGate().run()
        #expect(first == second)
    }

    @Test("the hierarchy has three levels and the root covers every message")
    func hierarchyIsThreeLevels() async throws {
        let driver = ContextGateDriver()
        let curation = try await driver.curation()
        #expect(curation.hierarchy.levels.count == 3)
        #expect(curation.curatorCalls == (driver.transcript.turns.count + 1) / 2)
        let expected = (0..<driver.transcript.turns.count).map(ContextMessage.id(forTurnIndex:)).sorted()
        #expect(curation.hierarchy.root?.coverage.messageIDs == expected)
    }

    @Test("the cover keeps older regions coarse and recent regions fine")
    func mixedResolutionCoverIsExact() async throws {
        let driver = ContextGateDriver()
        let curation = try await driver.curation()
        let cover = driver.mixedResolutionCover(curation.hierarchy)
        #expect(!cover.isEmpty)
        #expect(cover.contains { $0.id == "endpoint-corrected" })
        #expect(cover.contains { $0.id == "tool-42" })
        #expect(!cover.contains { $0.id == "endpoint-start" })
        #expect(!cover.contains { $0.id == "timeout-first" })
    }

    @Test("the decision record renders as JSON and Markdown")
    func recordRenders() async throws {
        let result = try await ContextGate().run()
        let data = try result.jsonData()
        let decoded = try JSONDecoder().decode(ContextGateResult.self, from: data)
        #expect(decoded == result)

        let markdown = result.markdown()
        #expect(markdown.contains("# Context hypothesis gate"))
        #expect(markdown.contains(result.decision.rawValue))
        for arm in result.arms {
            #expect(markdown.contains(arm.arm.rawValue))
        }
    }
}
