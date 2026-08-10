// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Ascendant turn update replay")
struct AscendantTurnUpdateStoreTests {
    @Test("retains ordered updates and reports terminal state")
    func orderedUpdates() async {
        let store = AscendantTurnUpdateStore(maxEvents: 4, maxBytes: 10_000)
        let timelineID = UUID()
        await store.start(timelineID: timelineID, clientTurnID: "turn-1")
        _ = await store.append(timelineID: timelineID, clientTurnID: "turn-1", kind: "assistant_text", text: "hello")
        _ = await store.append(timelineID: timelineID, clientTurnID: "turn-1", kind: "completion", terminal: true)

        let replay = await store.replay(timelineID: timelineID, clientTurnID: "turn-1")
        #expect(replay.updates.map(\.sequence) == [1, 2])
        #expect(replay.updates.last?.terminal == true)
        #expect(replay.terminal)
        #expect(!replay.compacted)
    }

    @Test("compaction never discards the newest update")
    func compaction() async {
        let store = AscendantTurnUpdateStore(maxEvents: 2, maxBytes: 10_000)
        let timelineID = UUID()
        await store.start(timelineID: timelineID, clientTurnID: "turn-2")
        for index in 0..<4 {
            _ = await store.append(timelineID: timelineID, clientTurnID: "turn-2", kind: "assistant_text", text: "\(index)")
        }

        let replay = await store.replay(timelineID: timelineID, clientTurnID: "turn-2", afterSequence: 0)
        #expect(replay.compacted)
        #expect(replay.updates.count == 2)
        #expect(replay.updates.last?.text == "3")
    }
}
