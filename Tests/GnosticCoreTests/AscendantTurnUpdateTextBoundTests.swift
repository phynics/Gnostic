// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import Testing

@testable import GnosticCore

/// How the update store keeps or visibly cuts text over one update's bound (issue #698).
@Suite("Ascendant turn update text bound")
struct AscendantTurnUpdateTextBoundTests {
    /// All retained updates. One replay page holds what fits the wire bound.
    private static func allUpdates(_ store: AscendantTurnUpdateStore, timelineID: UUID) async throws -> [AscendantTurnUpdate] {
        var updates: [AscendantTurnUpdate] = []
        var after = 0
        while true {
            let page = try await store.replay(timelineID: timelineID, clientTurnID: "turn", afterSequence: after)
            updates += page.updates
            guard let next = page.nextSequence else { return updates }
            after = next
        }
    }

    private static func assembled(_ updates: [AscendantTurnUpdate]) -> String {
        updates.filter(\.carriesAssistantText).compactMap(\.text).joined()
    }

    @Test(
        "assistant text over the bound assembles whole, in order, on scalar boundaries",
        arguments: [
            String(repeating: "a", count: 2_455),
            String(repeating: "a", count: 798) + String(repeating: "\u{1F600}\u{E9}\u{65E5}", count: 200),
            // JSON escaping grows these past the encoded limit well before 800 bytes.
            String(repeating: "\"", count: 3_000),
            String(repeating: "\n\\/", count: 1_000),
            String(repeating: "\u{1}", count: 2_000),
        ]
    )
    func longTextAssemblesWhole(text: String) async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "assistant_text", text: text)

        let updates = try await Self.allUpdates(store, timelineID: timelineID)
        #expect(Array(Self.assembled(updates).unicodeScalars) == Array(text.unicodeScalars))
        #expect(updates.count > 1)
        #expect(updates.map(\.sequence) == Array(1...updates.count))
        #expect(updates.allSatisfy { ($0.text?.utf8.count ?? 0) <= 800 })
    }

    @Test("assistant text within the bound stays one update")
    func shortTextStaysOneUpdate() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        let text = String(repeating: "a", count: 800)
        _ = try await store.append(timelineID: timelineID, clientTurnID: "turn", kind: "assistant_text", text: text)

        let updates = try await Self.allUpdates(store, timelineID: timelineID)
        #expect(updates.map(\.text) == [text])
    }

    @Test("a diagnostic text field is cut, not split")
    func errorTextIsNotSplit() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        _ = try await store.append(
            timelineID: timelineID, clientTurnID: "turn", kind: "error",
            text: String(repeating: "a", count: 2_000), terminal: true
        )

        let updates = try await Self.allUpdates(store, timelineID: timelineID)
        #expect(updates.count == 1)
        #expect(updates.first?.text?.utf8.count == 800)
    }

    @Test("tool content over its bound ends in a visible marker")
    func toolContentIsVisiblyCut() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        _ = try await store.append(
            timelineID: timelineID, clientTurnID: "turn", kind: "tool_state",
            toolState: AscendantToolState(
                toolCallID: "call", status: "completed", content: String(repeating: "\u{65E5}", count: 200)
            )
        )

        let content = try #require(try await store.replay(timelineID: timelineID, clientTurnID: "turn").updates.first?.toolState?.content)
        #expect(content.hasSuffix("…[truncated]"))
        #expect(content.utf8.count <= 256)
    }

    @Test("tool content within its bound carries no marker")
    func shortToolContentIsUnchanged() async throws {
        let store = AscendantTurnUpdateStore()
        let timelineID = UUID()
        let text = String(repeating: "a", count: 256)
        _ = try await store.append(
            timelineID: timelineID, clientTurnID: "turn", kind: "tool_state",
            toolState: AscendantToolState(toolCallID: "call", status: "completed", content: text)
        )

        let content = try await store.replay(timelineID: timelineID, clientTurnID: "turn").updates.first?.toolState?.content
        #expect(content == text)
    }

    @Test("a retention snapshot that loses text says so, across repeated compaction")
    func compactedSnapshotIsVisiblyCut() async throws {
        let store = AscendantTurnUpdateStore(maxEvents: 4, maxBytes: 10_000)
        let timelineID = UUID()
        for _ in 0..<6 {
            _ = try await store.append(
                timelineID: timelineID, clientTurnID: "turn", kind: "assistant_text",
                text: String(repeating: "a", count: 2_000)
            )
        }

        let replay = try await store.replay(timelineID: timelineID, clientTurnID: "turn")
        #expect(replay.compacted)
        let snapshot = try #require(replay.updates.first)
        #expect(snapshot.updateKind == .assistantTextSnapshot)
        #expect(snapshot.text?.hasSuffix("…[truncated]") == true)
        #expect((snapshot.text?.utf8.count ?? 0) <= 800)
    }
}
