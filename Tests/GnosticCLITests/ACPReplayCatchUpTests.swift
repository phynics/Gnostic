// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import GnosticACPFrontend
import GnosticCore
import Testing

/// What a prompt takes from replay after it missed live updates (issue #698).
@Suite("ACP replay catch-up")
struct ACPReplayCatchUpTests {
    private func permission(_ id: String, _ status: String) -> TurnUpdate {
        TurnUpdate(
            sequence: 1,
            kind: .permissionState,
            permissionState: TurnPermissionState(correlationID: id, toolCallID: "tool", title: "Run", status: status)
        )
    }

    private func snapshot(_ text: String) -> TurnUpdate {
        TurnUpdate(sequence: 9, kind: .assistantTextSnapshot, text: text)
    }

    @Test("a mid-Turn catch-up mediates only a request still pending")
    func skipsResolvedRequests() {
        let updates = [permission("settled", "pending"), permission("open", "pending"), permission("settled", "selected")]
        #expect(ACPReplayCatchUp.permissionsToSkip(in: updates, turnEnded: false) == ["settled"])
    }

    @Test("after the Turn ended, catch-up asks about no request")
    func skipsEveryRequestAfterTheTurn() {
        let updates = [permission("open", "pending")]
        #expect(ACPReplayCatchUp.permissionsToSkip(in: updates, turnEnded: true) == ["open"])
    }

    @Test("a snapshot gives a client only the text it does not hold")
    func snapshotDropsDeliveredText() {
        let result = ACPReplayCatchUp.removingDeliveredText(from: snapshot("Aé日BC"), deliveredTextBytes: 6)
        #expect(result?.text == "BC")
        #expect(result?.sequence == 9)
    }

    @Test("a client with no text receives the whole snapshot")
    func snapshotIsWholeForAFreshClient() {
        #expect(ACPReplayCatchUp.removingDeliveredText(from: snapshot("ABC"), deliveredTextBytes: 0)?.text == "ABC")
    }

    @Test("a snapshot that adds nothing is dropped")
    func snapshotWithNothingNewIsDropped() {
        #expect(ACPReplayCatchUp.removingDeliveredText(from: snapshot("ABC"), deliveredTextBytes: 3) == nil)
    }

    @Test("a snapshot cut before the client's position yields only the marker")
    func cutSnapshotKeepsTheMarker() {
        let cut = "AB" + TurnUpdate.truncationMarker
        let result = ACPReplayCatchUp.removingDeliveredText(from: snapshot(cut), deliveredTextBytes: 500)
        #expect(result?.text == TurnUpdate.truncationMarker)
    }

    @Test("a snapshot cut after the client's position keeps the new text and the marker")
    func cutSnapshotKeepsNewText() {
        let cut = "ABCD" + TurnUpdate.truncationMarker
        let result = ACPReplayCatchUp.removingDeliveredText(from: snapshot(cut), deliveredTextBytes: 2)
        #expect(result?.text == "CD" + TurnUpdate.truncationMarker)
    }

    @Test("a snapshot keeps its tool states when it adds no text")
    func snapshotKeepsToolStates() {
        let update = TurnUpdate(
            sequence: 9, kind: .assistantTextSnapshot, text: "ABC",
            toolStates: [TurnToolState(toolCallID: "tool", status: "completed")]
        )
        let result = ACPReplayCatchUp.removingDeliveredText(from: update, deliveredTextBytes: 3)
        #expect(result?.text == nil)
        #expect(result?.toolStates.count == 1)
    }

    @Test("other updates pass through unchanged")
    func otherUpdatesAreUntouched() {
        let update = TurnUpdate(sequence: 2, kind: .assistantText, text: "ABC")
        #expect(ACPReplayCatchUp.removingDeliveredText(from: update, deliveredTextBytes: 3)?.text == "ABC")
    }
}
