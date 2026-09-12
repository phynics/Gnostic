// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Ascendant turn update vocabulary")
struct AscendantTurnUpdateVocabularyTests {
    @Test("the declared update vocabulary is exactly what producers emit")
    func declaredKindsMatchProducers() {
        #expect(AscendantTurnUpdateKind.allCases.map(\.rawValue).sorted() == [
            "assistant_text",
            "assistant_text_snapshot",
            "cancellation",
            "completion",
            "error",
            "permission_state",
            "tool_call",
            "tool_state",
        ])
    }

    @Test("'cancelled' is not an update kind")
    func cancelledIsNotAnUpdateKind() {
        // ACPDispatcher tested for this spelling defensively. No producer has
        // ever emitted it; the terminal cancellation kind is "cancellation".
        #expect(AscendantTurnUpdateKind(rawValue: "cancelled") == nil)
    }

    @Test("terminal failure detection covers every failure kind a producer emits")
    func terminalFailureDetection() {
        #expect(AscendantTurnUpdate(sequence: 1, kind: .error, terminal: true).isTerminalFailure)
        #expect(AscendantTurnUpdate(sequence: 2, kind: .cancellation, terminal: true).isTerminalFailure)
        #expect(!AscendantTurnUpdate(sequence: 3, kind: .completion, terminal: true).isTerminalFailure)
        #expect(!AscendantTurnUpdate(sequence: 4, kind: .assistantText, text: "hi").isTerminalFailure)
    }

    @Test("assistant text detection covers streamed and compacted text")
    func assistantTextDetection() {
        #expect(AscendantTurnUpdate(sequence: 1, kind: .assistantText, text: "a").carriesAssistantText)
        #expect(AscendantTurnUpdate(sequence: 2, kind: .assistantTextSnapshot, text: "b").carriesAssistantText)
        #expect(!AscendantTurnUpdate(sequence: 3, kind: .toolCall).carriesAssistantText)
        #expect(!AscendantTurnUpdate(sequence: 4, kind: .completion).carriesAssistantText)
    }

    @Test("an unknown wire kind decodes without becoming a known kind")
    func unknownKindStaysUnknown() throws {
        let wire = #"{"protocolMajor":2,"sequence":1,"kind":"future_kind","toolStates":[],"permissionStates":[],"terminal":false}"#
        let decoded = try JSONDecoder().decode(AscendantTurnUpdate.self, from: Data(wire.utf8))

        #expect(decoded.kind == "future_kind")
        #expect(decoded.updateKind == nil)
        #expect(!decoded.carriesAssistantText)
        #expect(!decoded.isTerminalFailure)
    }

    @Test("typed kinds encode to the existing wire spellings")
    func typedKindsPreserveWireSpelling() throws {
        let update = AscendantTurnUpdate(sequence: 7, kind: .assistantTextSnapshot, text: "x")
        let data = try JSONEncoder().encode(update)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kind"] as? String == "assistant_text_snapshot")
    }

    @Test("tool and permission status vocabularies are declared")
    func statusVocabulariesAreDeclared() {
        #expect(AscendantToolStatus.allCases.map(\.rawValue).sorted() == [
            "completed", "failed", "in_progress", "pending",
        ])
        #expect(AscendantPermissionStatus.allCases.map(\.rawValue).sorted() == [
            "connection_lost", "denied", "pending", "selected",
        ])
        #expect(AscendantToolState(toolCallID: "t", status: .inProgress).status == "in_progress")
        #expect(AscendantPermissionState(
            correlationID: "c", toolCallID: "t", title: "T", status: .selected
        ).status == "selected")
    }
}
