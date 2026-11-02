import GnosticProtocol
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

enum ACPPermissionBridge {
    static func parameters(sessionID: String, state: TurnPermissionState) -> GnosticJSONValue {
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

    /// Waits for a client's answer no longer than the Node's own bound, so a
    /// silent client cannot hold the prompt after the Node has moved on.
    ///
    /// - Returns: The answer, or `nil` when the bound passed. The caller stops
    ///   waiting, but the client is not told, and a later answer is dropped.
    /// - Throws: The request's failure, including a cancellation from a session close.
    static func boundedAnswer(
        from request: Task<GnosticJSONValue, any Error>,
        bound: Duration = AscendantPermissionCoordinator.defaultUnansweredBound
    ) async throws -> GnosticJSONValue? {
        let expiry = Task { () -> Bool in
            guard (try? await Task.sleep(for: bound)) != nil else { return false }
            request.cancel()
            return true
        }
        defer { expiry.cancel() }
        do {
            return try await request.value
        } catch is CancellationError {
            // Only the bound withdraws quietly. A session close still ends the prompt.
            expiry.cancel()
            guard await expiry.value else { throw CancellationError() }
            return nil
        }
    }
}
