// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore
import PKContracts

enum ACPPermissionBridge {
    static func parameters(sessionID: String, state: AscendantPermissionState) -> AnyCodable {
        .dictionary([
            "sessionId": .string(sessionID),
            "toolCall": .dictionary([
                "toolCallId": .string(state.toolCallID),
                "title": .string(state.title),
                "status": .string("pending"),
            ]),
            "options": .array([
                .dictionary([
                    "optionId": .string("allow_once"),
                    "name": .string("Allow once"),
                    "kind": .string("allow_once"),
                ]),
                .dictionary([
                    "optionId": .string("reject_once"),
                    "name": .string("Reject once"),
                    "kind": .string("reject_once"),
                ]),
            ]),
        ])
    }

    static func approved(from response: AnyCodable) -> Bool? {
        guard case let .dictionary(root) = response,
              case let .dictionary(outcome)? = root["outcome"],
              case let .string(kind)? = outcome["outcome"] else { return nil }
        if kind == "cancelled" { return false }
        guard kind == "selected", case let .string(optionID)? = outcome["optionId"] else { return nil }
        switch optionID {
        case "allow_once": return true
        case "reject_once": return false
        default: return nil
        }
    }
}
