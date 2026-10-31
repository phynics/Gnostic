import GnosticProtocol
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

enum ACPPermissionBridge {
    static func parameters(sessionID: String, state: AscendantPermissionState) -> GnosticJSONValue {
        .dictionary([
            "sessionId": .string(sessionID),
            "title": .string(state.title),
            "subject": .dictionary([
                "type": .string("tool_call"),
                "toolCall": .dictionary([
                    "toolCallId": .string(state.toolCallID),
                    "title": .string(state.title),
                    "status": .string("pending"),
                ]),
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

    /// What an ACP client said about one permission request.
    enum Answer: Equatable {
        case approved
        case denied
        /// The client ended the request without deciding. This is not a denial.
        case undecided
    }

    /// Reads a client's response, or returns `nil` when it is malformed.
    static func answer(from response: GnosticJSONValue) -> Answer? {
        guard case let .dictionary(root) = response,
              case let .dictionary(outcome)? = root["outcome"],
              case let .string(kind)? = outcome["outcome"] else { return nil }
        if kind == "cancelled" { return .undecided }
        guard kind == "selected", case let .string(optionID)? = outcome["optionId"] else { return nil }
        switch optionID {
        case "allow_once": return .approved
        case "reject_once": return .denied
        default: return nil
        }
    }
}
