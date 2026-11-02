// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Ascendant turn update vocabulary")
struct AscendantTurnUpdateVocabularyTests {
    @Test("the declared update vocabulary is exactly what producers emit")
    func declaredKindsMatchProducers() {
        #expect(TurnUpdateKind.allCases.map(\.rawValue).sorted() == [
            "assistant_text",
            "assistant_text_snapshot",
            "cancellation",
            "completion",
            "error",
            "permission_state",
            "plan",
            "thought",
            "tool_call",
            "tool_state",
        ])
    }

    @Test("'cancelled' is not an update kind")
    func cancelledIsNotAnUpdateKind() {
        // ACPDispatcher tested for this spelling defensively. No producer has
        // ever emitted it; the terminal cancellation kind is "cancellation".
        #expect(TurnUpdateKind(rawValue: "cancelled") == nil)
    }

    @Test("terminal failure detection covers every failure kind a producer emits")
    func terminalFailureDetection() {
        #expect(TurnUpdate(sequence: 1, kind: .error, terminal: true).isTerminalFailure)
        #expect(TurnUpdate(sequence: 2, kind: .cancellation, terminal: true).isTerminalFailure)
        #expect(!TurnUpdate(sequence: 3, kind: .completion, terminal: true).isTerminalFailure)
        #expect(!TurnUpdate(sequence: 4, kind: .assistantText, text: "hi").isTerminalFailure)
    }

    @Test("assistant text detection covers streamed and compacted text")
    func assistantTextDetection() {
        #expect(TurnUpdate(sequence: 1, kind: .assistantText, text: "a").carriesAssistantText)
        #expect(TurnUpdate(sequence: 2, kind: .assistantTextSnapshot, text: "b").carriesAssistantText)
        #expect(!TurnUpdate(sequence: 3, kind: .toolCall).carriesAssistantText)
        #expect(!TurnUpdate(sequence: 4, kind: .completion).carriesAssistantText)
        // A thought and a plan are never assistant text.
        #expect(!TurnUpdate(sequence: 5, kind: .thought, text: "hm").carriesAssistantText)
        #expect(!TurnUpdate(sequence: 6, kind: .plan, plan: TurnPlan(planID: "p", entries: [])).carriesAssistantText)
    }

    @Test("an update without a plan encodes as it did before plans existed, and an old one decodes")
    func planFieldsAreAdditive() throws {
        let plain = try JSONEncoder().encode(TurnUpdate(sequence: 1, kind: .assistantText, text: "a"))
        let object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(object["plan"] == nil)
        #expect(object["plans"] == nil)

        let old = #"{"protocolMajor":3,"sequence":1,"kind":"assistant_text","text":"a","toolStates":[],"permissionStates":[],"terminal":false}"#
        let decoded = try JSONDecoder().decode(TurnUpdate.self, from: Data(old.utf8))
        #expect(decoded.plan == nil && decoded.plans.isEmpty)

        let planned = TurnUpdate(sequence: 2, kind: .plan, plan: TurnPlan(
            planID: "p", entries: [TurnPlanEntry(content: "c", priority: "high", status: "pending")]
        ))
        let roundTrip = try JSONDecoder().decode(TurnUpdate.self, from: JSONEncoder().encode(planned))
        #expect(roundTrip == planned)
    }

    @Test("an unknown wire kind decodes without becoming a known kind")
    func unknownKindStaysUnknown() throws {
        let wire = #"{"protocolMajor":3,"sequence":1,"kind":"future_kind","toolStates":[],"permissionStates":[],"terminal":false}"#
        let decoded = try JSONDecoder().decode(TurnUpdate.self, from: Data(wire.utf8))

        #expect(decoded.kind == "future_kind")
        #expect(decoded.updateKind == nil)
        #expect(!decoded.carriesAssistantText)
        #expect(!decoded.isTerminalFailure)
    }

    @Test("typed kinds encode to the existing wire spellings")
    func typedKindsPreserveWireSpelling() throws {
        let update = TurnUpdate(sequence: 7, kind: .assistantTextSnapshot, text: "x")
        let data = try JSONEncoder().encode(update)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kind"] as? String == "assistant_text_snapshot")
    }

    @Test("tool and permission status vocabularies are declared")
    func statusVocabulariesAreDeclared() {
        #expect(TurnToolStatus.allCases.map(\.rawValue).sorted() == [
            "completed", "failed", "in_progress", "pending",
        ])
        #expect(TurnPermissionStatus.allCases.map(\.rawValue).sorted() == [
            "connection_lost", "denied", "pending", "selected", "unavailable",
        ])
        #expect(TurnToolState(toolCallID: "t", status: .inProgress).status == "in_progress")
        #expect(TurnPermissionState(
            correlationID: "c", toolCallID: "t", title: "T", status: .selected
        ).status == "selected")
    }
}
