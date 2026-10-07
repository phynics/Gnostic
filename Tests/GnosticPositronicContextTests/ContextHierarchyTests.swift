// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticKit
import Testing
import GnosticPositronicBackend

@testable import GnosticPositronicContext

@Suite("Context carry reduction and chronological hierarchy")
struct ContextHierarchyTests {
    private let timelineID = "tl-1"

    @Test("carry reduction deduplicates goals and keeps provenance")
    func reductionDeduplicatesGoals() {
        let first = item(id: "goal-a", category: .goals, text: "Ship the context gate.", citation: "m-000000001")
        let second = item(id: "goal-b", category: .goals, text: "ship the   context gate.", citation: "m-000000002")
        let reduced = ContextCarryReducer().reduce([
            ContextCarryState(items: [first]),
            ContextCarryState(items: [second]),
        ])
        #expect(reduced.items.count == 1)
        #expect(reduced.items[0].id == "goal-a")
        #expect(reduced.items[0].citations.map(\.messageID) == ["m-000000001", "m-000000002"])
    }

    @Test("carry reduction keeps MQTT in history and Zenoh active")
    func reductionAppliesSupersession() {
        let mqtt = item(id: "transport-mqtt", category: .decisions, text: "Use MQTT for transport.", citation: "m-000000001")
        let zenoh = item(
            id: "transport-zenoh",
            category: .decisions,
            text: "Use Zenoh for transport.",
            citation: "m-000000005",
            supersedes: "transport-mqtt"
        )
        let reduced = ContextCarryReducer().reduce([
            ContextCarryState(items: [mqtt]),
            ContextCarryState(items: [zenoh]),
        ])
        #expect(reduced.activeItems.map(\.id) == ["transport-zenoh"])
        #expect(reduced.historicalItems.map(\.id) == ["transport-mqtt"])
        #expect(reduced.historicalItems[0].epistemicStatus == .superseded)
    }

    @Test("a constraint survives unless a later claim explicitly supersedes it")
    func constraintRequiresExplicitSupersession() {
        let constraint = item(id: "c1", category: .constraints, text: "Do not use SQLite.", citation: "m-000000001")
        let alone = ContextCarryReducer().reduce([ContextCarryState(items: [constraint])])
        #expect(alone.activeItems.map(\.id) == ["c1"])

        let replacement = item(
            id: "c2",
            category: .constraints,
            text: "Use SQLite for the cache.",
            citation: "m-000000004",
            supersedes: "c1"
        )
        let replaced = ContextCarryReducer().reduce([ContextCarryState(items: [constraint, replacement])])
        #expect(replaced.activeItems.map(\.id) == ["c2"])
        #expect(replaced.historicalItems.map(\.id) == ["c1"])
    }

    @Test("a resolved question leaves the active set")
    func resolvedQuestionLeavesActiveSet() {
        let question = item(id: "q", category: .unresolvedQuestions, text: "Which transport?", citation: "m-000000001")
        let answer = item(
            id: "a",
            category: .decisions,
            text: "Use Zenoh.",
            citation: "m-000000005",
            supersedes: "q"
        )
        let reduced = ContextCarryReducer().reduce([ContextCarryState(items: [question, answer])])
        #expect(reduced.activeItems.map(\.id) == ["a"])
        #expect(reduced.historicalItems.map(\.id) == ["q"])
    }

    @Test("exact pins union and de-duplicate by ID")
    func exactPinsUnion() {
        let first = item(id: "pin", category: .exactPins, text: "port 8317", citation: "m-000000001", origin: .systemConstraint)
        let second = item(id: "pin", category: .exactPins, text: "port 9000", citation: "m-000000002", origin: .systemConstraint)
        let reduced = ContextCarryReducer().reduce([
            ContextCarryState(items: [first]),
            ContextCarryState(items: [second]),
        ])
        #expect(reduced.items.count == 1)
        #expect(reduced.items[0].text == "port 8317")
    }

    @Test("the hierarchy covers the source exactly with no gaps or overlaps")
    func exactCoverage() {
        let leaves = syntheticLeaves(16)
        let hierarchy = ContextHierarchyBuilder().build(leaves: leaves, timelineID: timelineID)
        #expect(hierarchy.leaves.count == 16)
        #expect(hierarchy.root?.coverage.messageIDs == allMessageIDs(16))

        for level in hierarchy.levels.dropFirst() {
            for parent in level {
                let childIDs = Set(parent.children)
                let children = hierarchy.nodes.filter { childIDs.contains($0.id) }
                #expect(ContextHierarchyBuilder.unionMessageIDs(children.map(\.coverage)) == parent.coverage.messageIDs)
            }
        }

        let allLeafIDs = leaves.flatMap { $0.coverage.messageIDs }
        #expect(Set(allLeafIDs).count == allLeafIDs.count)
    }

    @Test("rebuilding from the same leaves gives an equivalent hierarchy")
    func deterministicRebuild() {
        let leaves = syntheticLeaves(20)
        let first = ContextHierarchyBuilder().build(leaves: leaves, timelineID: timelineID)
        let second = ContextHierarchyBuilder().build(leaves: leaves, timelineID: timelineID)
        #expect(first == second)
        #expect(first.root?.id == second.root?.id)
    }

    @Test("fan-out stays within the descriptor bounds")
    func fanOutWithinBounds() {
        let descriptor = ContextDescriptor.default
        let leaves = syntheticLeaves(20)
        let hierarchy = ContextHierarchyBuilder(descriptor: descriptor).build(leaves: leaves, timelineID: timelineID)
        for level in hierarchy.levels.dropFirst().dropLast() {
            for parent in level {
                #expect(parent.children.count >= descriptor.minimumFanOut)
                #expect(parent.children.count <= descriptor.maximumFanOut)
            }
        }
        #expect(hierarchy.root?.coverage.messageIDs == allMessageIDs(20))
    }

    @Test("semantic tags do not affect which source a node owns")
    func semanticTagsDoNotAffectCoverage() {
        let leaves = syntheticLeaves(12)
        let relabeled = leaves.map { node in
            ContextNode(
                timelineID: node.timelineID,
                coverage: node.coverage,
                children: node.children,
                synopsis: node.synopsis,
                carry: ContextCarryState(items: [
                    item(id: "label", category: .facts, text: "unrelated tag", citation: "m-000000001")
                ]),
                curatorVersion: node.curatorVersion
            )
        }
        let first = ContextHierarchyBuilder().build(leaves: leaves, timelineID: timelineID)
        let second = ContextHierarchyBuilder().build(leaves: relabeled, timelineID: timelineID)
        #expect(first.root?.coverage == second.root?.coverage)
        #expect(first.root?.children == second.root?.children)
    }

    @Test("the fixture hierarchy reduces carry across episodes")
    func fixtureHierarchyReducesCarry() async throws {
        let replay = ContextEpisodeReplay(timelineID: timelineID, episodeSize: 8)
        let transcript = ContextFixtureTranscript.longHorizon(unrelatedTurnCount: 2)
        let leaves = try await replay.replay(transcript: transcript, descriptor: .default, curator: FixtureContextCurator())
        let validator = ContextProposalValidator()
        var active = ContextCarryState()
        var nodes: [ContextNode] = []
        for leaf in leaves {
            let node = try validator.validate(leaf, expectedTimelineID: timelineID, activeCarry: active)
            nodes.append(node)
            active = ContextCarryState(items: active.items + node.carry.items)
        }
        let hierarchy = ContextHierarchyBuilder().build(leaves: nodes, timelineID: timelineID)
        #expect(hierarchy.leaves.count == nodes.count)
        #expect(hierarchy.root?.coverage.messageIDs == (0..<transcript.turns.count).map(ContextMessage.id(forTurnIndex:)).sorted())
        let activeIDs = hierarchy.root?.carry.activeItems.map(\.id) ?? []
        #expect(activeIDs.contains("endpoint-corrected"))
        #expect(!activeIDs.contains("endpoint-start"))
    }

    private func syntheticLeaves(_ count: Int) -> [ContextNode] {
        (0..<count).map { index in
            ContextNode(
                timelineID: timelineID,
                coverage: ContextSourceRange.hostComputed(
                    timelineID: timelineID,
                    messageIDs: [ContextMessage.id(forTurnIndex: index)]
                ),
                curatorVersion: "fixture-v1"
            )
        }
    }

    private func allMessageIDs(_ count: Int) -> [String] {
        (0..<count).map(ContextMessage.id(forTurnIndex:)).sorted()
    }

    private func item(
        id: String,
        category: ContextCarryCategory,
        text: String,
        citation: String,
        supersedes: String? = nil,
        origin: ContextClaimOrigin = .assistantAssertion
    ) -> ContextCarryItem {
        ContextCarryItem(
            id: id,
            category: category,
            text: text,
            origin: origin,
            epistemicStatus: .asserted,
            citations: [ContextCitation(messageID: citation)],
            supersedes: supersedes
        )
    }
}
