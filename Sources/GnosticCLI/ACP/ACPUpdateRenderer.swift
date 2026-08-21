// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore
import PKContracts

struct ACPRenderedNotification: Sendable {
    let method: String
    let params: AnyCodable
}

enum ACPUpdateRenderer {
    static func updates(
        sessionID: String,
        turnID: String,
        update: AscendantTurnUpdate,
        replayed: Bool
    ) -> [ACPRenderedNotification] {
        var metadata: [String: AnyCodable] = [
            "clientTurnID": .string(turnID),
            "sequence": .integer(Int64(update.sequence)),
            "kind": .string(update.kind),
            "replayed": .boolean(replayed),
        ]

        var payloads: [AnyCodable] = []
        if update.kind == "assistant_text" || update.kind == "assistant_text_snapshot",
           let text = update.text {
            payloads.append(.dictionary([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .dictionary(["type": .string("text"), "text": .string(text)]),
                "_meta": .dictionary(metadata),
            ]))
        }
        if let toolState = update.toolState {
            payloads.append(toolPayload(toolState, initial: update.kind == "tool_call", metadata: metadata))
        }
        for toolState in update.toolStates {
            metadata["compacted"] = .boolean(true)
            payloads.append(toolPayload(toolState, initial: false, metadata: metadata))
        }

        return payloads.map { payload in
            ACPRenderedNotification(
                method: "session/update",
                params: .dictionary([
                    "sessionId": .string(sessionID),
                    "update": payload,
                ])
            )
        }
    }

    private static func toolPayload(
        _ state: AscendantToolState,
        initial: Bool,
        metadata: [String: AnyCodable]
    ) -> AnyCodable {
        var payload: [String: AnyCodable] = [
            "sessionUpdate": .string(initial ? "tool_call" : "tool_call_update"),
            "toolCallId": .string(state.toolCallID),
            "status": .string(state.status),
            "_meta": .dictionary(metadata),
        ]
        if let title = state.title ?? (initial ? state.toolCallID : nil) {
            payload["title"] = .string(title)
        }
        if let content = state.content {
            payload["content"] = .array([.dictionary([
                "type": .string("content"),
                "content": .dictionary(["type": .string("text"), "text": .string(content)]),
            ])])
        }
        return .dictionary(payload)
    }
}
