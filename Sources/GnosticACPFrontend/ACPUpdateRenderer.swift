import GnosticProtocol
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

struct ACPRenderedNotification: Sendable {
    let method: String
    let params: GnosticJSONValue
}

enum ACPUpdateRenderer {
    static func updates(
        sessionID: String,
        turnID: String,
        update: TurnUpdate,
        replayed: Bool
    ) -> [ACPRenderedNotification] {
        var metadata: [String: GnosticJSONValue] = [
            "clientTurnID": .string(turnID),
            "sequence": .integer(Int64(update.sequence)),
            "kind": .string(update.kind),
            "replayed": .boolean(replayed),
        ]

        var payloads: [GnosticJSONValue] = []
        if update.carriesAssistantText, let text = update.text {
            payloads.append(.dictionary([
                "sessionUpdate": .string("agent_message_chunk"),
                "messageId": .string("acp:agent:\(turnID)"),
                "content": .dictionary(["type": .string("text"), "text": .string(text)]),
                "_meta": .dictionary(metadata),
            ]))
        }
        if update.updateKind == .thought, let text = update.text {
            payloads.append(.dictionary([
                "sessionUpdate": .string("agent_thought_chunk"),
                "messageId": .string("acp:thought:\(turnID)"),
                "content": .dictionary(["type": .string("text"), "text": .string(text)]),
                "_meta": .dictionary(metadata),
            ]))
        }
        if let toolState = update.toolState {
            payloads.append(toolPayload(toolState, initial: update.updateKind == .toolCall, metadata: metadata))
        }
        for toolState in update.toolStates {
            metadata["compacted"] = .boolean(true)
            payloads.append(toolPayload(toolState, initial: false, metadata: metadata))
        }
        // A plan update holds the whole plan and replaces the plan with its ID. A snapshot
        // holds the latest plan of each ID that retention folded.
        for plan in update.plans {
            var planMetadata = metadata
            planMetadata["compacted"] = .boolean(true)
            payloads.append(planPayload(plan, metadata: planMetadata))
        }
        if let plan = update.plan {
            payloads.append(planPayload(plan, metadata: metadata))
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

    /// An ACP v2 `plan_update`. A plan that lost entries ends in a marker entry and
    /// carries `_meta.truncated`, so a client that ignores `_meta` still sees the cut.
    private static func planPayload(
        _ plan: TurnPlan,
        metadata: [String: GnosticJSONValue]
    ) -> GnosticJSONValue {
        var metadata = metadata
        var entries = plan.entries.map { entry in
            GnosticJSONValue.dictionary([
                "content": .string(entry.content),
                "priority": .string(entry.priority),
                "status": .string(entry.status),
            ])
        }
        if plan.truncated {
            metadata["truncated"] = .boolean(true)
            entries.append(.dictionary([
                "content": .string(TurnUpdate.truncationMarker),
                "priority": .string("low"),
                "status": .string("pending"),
            ]))
        }
        return .dictionary([
            "sessionUpdate": .string("plan_update"),
            "plan": .dictionary([
                "type": .string("items"),
                "planId": .string(plan.planID),
                "entries": .array(entries),
            ]),
            "_meta": .dictionary(metadata),
        ])
    }

    private static func toolPayload(
        _ state: TurnToolState,
        initial: Bool,
        metadata: [String: GnosticJSONValue]
    ) -> GnosticJSONValue {
        var payload: [String: GnosticJSONValue] = [
            "sessionUpdate": .string("tool_call_update"),
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
