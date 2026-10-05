// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// A read-only projection of a Turn's backend-neutral updates.
///
/// Every backend emits ``AscendantTurnUpdate`` values while a Turn runs. This
/// view folds those values into the parts a consumer usually wants: the
/// assistant output, the latest state of each tool call, the permission states,
/// and the terminal outcome. It works for any backend, and ACP and Letta supply
/// it because they already emit the same updates.
public struct TurnTranscript: Sendable, Equatable {
    /// The updates the view folded, in the order they arrived.
    public let updates: [AscendantTurnUpdate]
    /// The assistant output after live fragments and snapshots are folded.
    public let assistantText: String
    /// The latest state of each announced tool call, in first-announced order.
    public let toolStates: [AscendantToolState]
    /// The latest permission states, in first-announced order.
    public let permissionStates: [AscendantPermissionState]
    /// The terminal update, when the Turn reached one.
    public let terminalUpdate: AscendantTurnUpdate?
    /// Whether the Turn reached a terminal update.
    public let isTerminal: Bool
    /// Whether the Turn failed by error or cancellation.
    public let failed: Bool

    /// Folds an ordered update list into a transcript view.
    public init(updates: [AscendantTurnUpdate]) {
        self.updates = updates

        var assistant = ""
        var tools: [AscendantToolState] = []
        var toolIndexByID: [String: Int] = [:]
        var permissions: [AscendantPermissionState] = []
        var permissionIndexByKey: [String: Int] = [:]
        var terminal: AscendantTurnUpdate?

        for update in updates.sorted(by: { $0.sequence < $1.sequence }) {
            if let text = update.text, update.carriesAssistantText {
                switch update.updateKind {
                case .assistantTextSnapshot:
                    assistant = text
                default:
                    assistant += text
                }
            }

            for state in update.toolStates + [update.toolState].compactMap({ $0 }) {
                if let index = toolIndexByID[state.toolCallID] {
                    tools[index] = state
                } else {
                    toolIndexByID[state.toolCallID] = tools.count
                    tools.append(state)
                }
            }

            for state in update.permissionStates + [update.permissionState].compactMap({ $0 }) {
                let key = "\(state.correlationID)|\(state.toolCallID)"
                if let index = permissionIndexByKey[key] {
                    permissions[index] = state
                } else {
                    permissionIndexByKey[key] = permissions.count
                    permissions.append(state)
                }
            }

            if update.terminal {
                terminal = update
            }
        }

        self.assistantText = assistant
        self.toolStates = tools
        self.permissionStates = permissions
        self.terminalUpdate = terminal
        self.isTerminal = terminal != nil
        self.failed = terminal?.isTerminalFailure ?? false
    }
}
