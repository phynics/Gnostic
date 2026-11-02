// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import Testing

@testable import GnosticCore

/// How the update store bounds, retains and compacts thoughts and plans (issue #724).
@Suite("Ascendant turn update thoughts and plans")
struct AscendantTurnUpdateThoughtPlanTests {
    private static func allUpdates(_ store: AscendantTurnUpdateStore, timelineID: UUID) async throws -> [TurnUpdate] {
        var updates: [TurnUpdate] = []
        var after = 0
        while true {
            let page = try await store.replay(timelineID: timelineID, clientTurnID: "turn", afterSequence: after)
            updates += page.updates
            guard let next = page.nextSequence else { return updates }
            after = next
        }
    }

    private static func plan(_ id: String = "plan", steps: Int, content: String = "step") -> TurnPlan {
        TurnPlan(planID: id, entries: (0..<steps).map {
            TurnPlanEntry(content: "\(content)-\($0)", priority: "medium", status: "pending")
        })
    }

    @Test(
        "a thought over the bound assembles whole, in order, on scalar boundaries",
        arguments: [
            String(repeating: "t", count: 2_455),
            String(repeating: "t", count: 798) + String(repeating: "\u{1F600}\u{E9}\u{65E5}", count: 200),
            String(repeating: "\"", count: 3_000),
        ]
    )
    func longThoughtAssemblesWhole(text: String) async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "thought", text: text)

        let updates = try await Self.allUpdates(store, timelineID: timelineID)
        #expect(Array(updates.compactMap(\.text).joined().unicodeScalars) == Array(text.unicodeScalars))
        #expect(updates.count > 1)
        #expect(updates.allSatisfy { $0.kind == "thought" && ($0.text?.utf8.count ?? 0) <= 800 })
        #expect(updates.allSatisfy { !$0.carriesAssistantText })
    }

    @Test("a thought does not count as streamed assistant text, so the result is still appended")
    func thoughtIsNotStreamedAssistantText() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        let clientTurnID = try await store.validatedClientTurnID("turn")
        _ = try await store.admit(timelineID: timelineID, clientTurnID: clientTurnID, message: "hello")
        _ = try await store.append(timelineID: timelineID, clientTurnID: clientTurnID, kind: "thought", text: "pondering")
        try await store.recordOutcome(timelineID: timelineID, clientTurnID: clientTurnID, outcome: .succeeded(text: "answer"))

        let updates = try await Self.allUpdates(store, timelineID: timelineID)
        #expect(updates.map(\.kind) == ["thought", "assistant_text", "completion"])
        #expect(updates.filter(\.carriesAssistantText).compactMap(\.text) == ["answer"])
        #expect(updates.last?.text == "answer")
    }

    @Test("a plan within the bound is kept whole")
    func planWithinBoundIsWhole() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        let plan = Self.plan(steps: 5)
        let appended = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "plan", plan: plan)
        #expect(appended.plan == plan)
        #expect(appended.plan?.truncated == false)
    }

    @Test("a plan over the bound loses trailing entries and says so, never a partial entry list without the flag")
    func overlongPlanIsVisiblyCut() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        let long = Self.plan(steps: 100, content: String(repeating: "p", count: 400))
        let appended = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "plan", plan: long)
        let plan = try #require(appended.plan)
        #expect(plan.truncated)
        #expect(!plan.entries.isEmpty && plan.entries.count < 100)
        #expect(plan.entries.allSatisfy { $0.content.utf8.count <= 120 && $0.content.hasSuffix(TurnUpdate.truncationMarker) })
        // The retained update decodes and stays within the update bound.
        let encoded = try JSONEncoder().encode(appended)
        #expect(encoded.count <= 1_200)
        #expect(try JSONDecoder().decode(TurnUpdate.self, from: encoded) == appended)
    }

    @Test("compaction keeps thought text out of the assistant snapshot and keeps the latest plan per ID")
    func compactionSeparatesThoughtsAndKeepsLatestPlan() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 6, maxBytes: 100_000)
        let timelineID = UUID()
        func append(_ kind: String, text: String? = nil, plan: TurnPlan? = nil) async throws {
            _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: kind, text: text, plan: plan)
        }
        try await append("assistant_text", text: "A")
        try await append("thought", text: "THOUGHT-1")
        try await append("plan", plan: Self.plan(steps: 1))
        try await append("thought", text: "THOUGHT-2")
        try await append("plan", plan: Self.plan(steps: 2))
        try await append("assistant_text", text: "B")
        for index in 0..<4 { try await append("thought", text: "late-\(index)") }
        try await append("assistant_text", text: "C")

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn")
        #expect(replay.compacted)
        let snapshot = try #require(replay.updates.first)
        #expect(snapshot.kind == "assistant_text_snapshot")
        #expect(snapshot.text == "AB")
        #expect(snapshot.plans.map(\.planID) == ["plan"])
        #expect(snapshot.plans.first?.entries.count == 2)
        #expect(!(snapshot.text ?? "").contains("THOUGHT"))

        // The folded view still gives assistant text without any thought text.
        let assistant = replay.updates.filter(\.carriesAssistantText)
        #expect(assistant.compactMap(\.text).joined() == "ABC")
        #expect(replay.updates.count <= 6)
    }

    @Test("a Turn with many thoughts keeps the retention bound, and the assistant text it folds stays correct")
    func manyThoughtsHonorRetentionLimits() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 8, maxBytes: 100_000)
        let timelineID = UUID()
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "assistant_text", text: "early ")
        for index in 0..<200 {
            _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "thought", text: "t\(index)")
        }
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "assistant_text", text: "late")

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn")
        #expect(replay.updates.count <= 8)
        #expect(replay.compacted)
        #expect(replay.updates.filter(\.carriesAssistantText).compactMap(\.text).joined() == "early late")
        #expect(replay.updates.contains { $0.updateKind == .assistantTextSnapshot && $0.text == "early " })
    }

    @Test("thoughts and plans survive a durable recovery")
    func durableRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turn-events-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let timelineID = UUID()
        do {
            let store = AscendantTurnUpdateStore()
            try await store.enableDurability(at: url)
            try await store.start(timelineID: timelineID, clientTurnID: "turn")
            _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "assistant_text", text: "hi")
            _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "thought", text: "hm")
            _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "plan", plan: Self.plan(steps: 2))
        }
        let recovered = AscendantTurnUpdateStore()
        try await recovered.enableDurability(at: url)
        let replay = try await recovered.replay(timelineID: timelineID, clientTurnID: "turn")
        #expect(replay.updates.map(\.kind) == ["assistant_text", "thought", "plan"])
        #expect(replay.updates.last?.plan?.entries.count == 2)
    }
}
