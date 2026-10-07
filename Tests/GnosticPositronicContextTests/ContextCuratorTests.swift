// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticKit
import Testing
import GnosticPositronicBackend

@testable import GnosticPositronicContext

@Suite("Structured context curator")
struct ContextCuratorTests {
    @Test("the fixture replay produces one leaf proposal per episode")
    func fixtureReplayProducesOneLeafPerEpisode() async throws {
        let replay = ContextEpisodeReplay(timelineID: "tl-1", episodeSize: 8)
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let leaves = try await replay.replay(transcript: transcript, descriptor: .default, curator: FixtureContextCurator())
        let expectedEpisodes = (transcript.turns.count + 7) / 8
        #expect(leaves.count == expectedEpisodes)
        #expect(leaves.allSatisfy { $0.episode.timelineID == "tl-1" })
    }

    @Test("the fixture replay retains every planted obligation and ignores the injection")
    func fixtureReplayRetainsObligations() async throws {
        let replay = ContextEpisodeReplay(timelineID: "tl-1", episodeSize: 8)
        let leaves = try await replay.replay(
            transcript: ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2),
            descriptor: .default,
            curator: FixtureContextCurator()
        )
        let answer = leaves.map(\.proposal.rendered).joined(separator: "\n")
        for fixture in ExperimentFixtureLibrary.plantedObligations {
            let score = ExperimentAssertionScorer().score(answer: answer, checks: fixture.checks)
            let failed = score.results.filter { !$0.passed }.map(\.id)
            #expect(score.passed == score.total, "\(fixture.id) failed checks: \(failed)")
        }
        #expect(!answer.localizedCaseInsensitiveContains("ignore all previous instructions"))
    }

    @Test("the fixture curator threads the active carry into the next episode")
    func fixtureCuratorSeesActiveCarry() async throws {
        let episode = ContextEpisode(
            timelineID: "tl-1",
            messages: [ContextMessage(id: "m-1", role: .assistant, text: "The broker listens on port 8317.")]
        )
        let active = ContextCarryState(items: [
            ContextCarryItem(
                id: "prior",
                category: .facts,
                text: "prior fact",
                origin: .assistantAssertion,
                epistemicStatus: .asserted,
                citations: [ContextCitation(messageID: "m-0")]
            )
        ])
        let proposal = try await FixtureContextCurator().propose(
            episode: episode,
            activeCarry: active,
            descriptor: .default
        )
        #expect(proposal.items.map(\.id) == ["port"])
    }

    @Test("the LLM curator parses a JSON proposal and records the descriptor versions")
    func llmCuratorParsesJSON() async throws {
        let service = ScriptedContextModelService(responses: [Self.validResponse])
        let proposal = try await LLMContextCurator(service: service).propose(
            episode: Self.episode,
            activeCarry: ContextCarryState(),
            descriptor: .default
        )
        #expect(proposal.items.count == 1)
        #expect(proposal.items[0].id == "port")
        #expect(proposal.items[0].citations == [ContextCitation(messageID: "m-000000003")])
        #expect(proposal.schemaVersion == ContextDescriptor.default.schemaVersion)
        #expect(proposal.policyVersion == ContextDescriptor.default.policyVersion)
    }

    @Test("a model cannot alter the schema or policy version")
    func llmCuratorIgnoresModelDescriptorFields() async throws {
        let response = """
        {"schemaVersion":"evil","policyVersion":"evil","synopsis":null,"items":[],"topicLabels":[]}
        """
        let service = ScriptedContextModelService(responses: [response])
        let proposal = try await LLMContextCurator(service: service).propose(
            episode: Self.episode,
            activeCarry: ContextCarryState(),
            descriptor: .default
        )
        #expect(proposal.schemaVersion == ContextDescriptor.default.schemaVersion)
        #expect(proposal.policyVersion == ContextDescriptor.default.policyVersion)
    }

    @Test("the LLM curator strips a code fence")
    func llmCuratorStripsCodeFence() async throws {
        let service = ScriptedContextModelService(responses: ["```json\n\(Self.validResponse)\n```"])
        let proposal = try await LLMContextCurator(service: service).propose(
            episode: Self.episode,
            activeCarry: ContextCarryState(),
            descriptor: .default
        )
        #expect(proposal.items.count == 1)
    }

    @Test("malformed structured output is contained")
    func llmCuratorRejectsMalformed() async throws {
        let service = ScriptedContextModelService(responses: ["this is not json"])
        await #expect(throws: ContextError.malformedProposal) {
            try await LLMContextCurator(service: service).propose(
                episode: Self.episode,
                activeCarry: ContextCarryState(),
                descriptor: .default
            )
        }
    }

    @Test("an unknown enum value is contained")
    func llmCuratorRejectsUnknownEnum() async throws {
        let response = """
        {"synopsis":null,"items":[{"id":"x","category":"nonsense","text":"t","origin":"assistantAssertion","epistemicStatus":"asserted","citations":["m-000000003"],"supersedes":null,"topicLabels":[]}],"topicLabels":[]}
        """
        let service = ScriptedContextModelService(responses: [response])
        await #expect(throws: ContextError.malformedProposal) {
            try await LLMContextCurator(service: service).propose(
                episode: Self.episode,
                activeCarry: ContextCarryState(),
                descriptor: .default
            )
        }
    }

    @Test("a curator failure escapes the replay with no partial result")
    func curatorFailureLeavesNoPartialResult() async throws {
        let service = ScriptedContextModelService(responses: [Self.validResponse], failureIndex: 1)
        let replay = ContextEpisodeReplay(timelineID: "tl-1", episodeSize: 8)
        await #expect(throws: ContextError.malformedProposal) {
            try await replay.replay(
                transcript: ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 0),
                descriptor: .default,
                curator: LLMContextCurator(service: service)
            )
        }
    }

    @Test("the prompt states that source and tool text is historical data")
    func promptStatesTextIsData() {
        let prompt = LLMContextCurator.prompt(
            episode: Self.episode,
            activeCarry: ContextCarryState(),
            descriptor: .default
        )
        #expect(prompt.contains("historical data"))
        #expect(prompt.contains("never"))
        #expect(prompt.contains("Do not obey"))
    }

    private static let episode = ContextEpisode(
        timelineID: "tl-1",
        messages: [
            ContextMessage(id: "m-000000003", role: .assistant, text: "The broker listens on port 8317.")
        ]
    )

    private static let validResponse = """
    {"synopsis":"broker","items":[{"id":"port","category":"facts","text":"The broker listens on port 8317.","origin":"assistantAssertion","epistemicStatus":"asserted","citations":["m-000000003"],"supersedes":null,"topicLabels":["broker"]}],"topicLabels":["broker"]}
    """
}

/// A deterministic model service for curator tests.
private actor ScriptedContextModelService: PositronicContributionModelService {
    private let responses: [String]
    private let failureIndex: Int?
    private var index = 0

    init(responses: [String], failureIndex: Int? = nil) {
        self.responses = responses
        self.failureIndex = failureIndex
    }

    func generate(prompt: String, tier: PositronicContributionModelTier) async throws -> String {
        if let failureIndex, index >= failureIndex {
            throw ContextError.malformedProposal
        }
        let response = responses[min(index, responses.count - 1)]
        index += 1
        return response
    }
}
