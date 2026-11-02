// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// A read-only projection of a Turn's backend-neutral updates.
///
/// Every backend emits ``TurnUpdate`` values while a Turn runs. This
/// view folds those values into the parts a consumer usually wants: the
/// assistant output, the thoughts and plans, the latest state of each tool call, the permission states,
/// and the terminal outcome. It works for any backend, and ACP and Letta supply
/// it because they already emit the same updates.
///
/// ``isTerminal`` is true only when the folded updates include a terminal
/// update the owner produced. A stream that stopped because observation was
/// lost (`GnosticTurnClient.updates(for:timelineID:providerID:)` throws)
/// yields no terminal update, so a transcript of what arrived is not terminal.
/// Replay the Turn to learn how it ended.
public struct TurnTranscript: Sendable, Equatable {
    /// The updates the view folded, in the order they arrived.
    public let updates: [TurnUpdate]
    /// The assistant output after live fragments and snapshots are folded.
    public let assistantText: String
    /// The thought text the folded updates carry. It is never part of
    /// ``assistantText``. Retention drops older thoughts, so after a compacted replay it
    /// holds only the thoughts that are still retained.
    public let thoughtText: String
    /// The latest plan for each plan ID, in first-announced order. A plan update
    /// replaces the plan with its ID.
    public let plans: [TurnPlan]
    /// The latest state of each announced tool call, in first-announced order.
    public let toolStates: [TurnToolState]
    /// The latest permission states, in first-announced order.
    public let permissionStates: [TurnPermissionState]
    /// The terminal update, when the Turn reached one.
    public let terminalUpdate: TurnUpdate?
    /// Whether the Turn reached a terminal update.
    public let isTerminal: Bool
    /// Whether the Turn failed by error or cancellation.
    public let failed: Bool

    /// Folds an ordered update list into a transcript view.
    public init(updates: [TurnUpdate]) {
        self.updates = updates

        var assistant = ""
        var thought = ""
        var plans: [TurnPlan] = []
        var tools: [TurnToolState] = []
        var toolIndexByID: [String: Int] = [:]
        var permissions: [TurnPermissionState] = []
        var permissionIndexByKey: [String: Int] = [:]
        var terminal: TurnUpdate?

        for update in updates.sorted(by: { $0.sequence < $1.sequence }) {
            if let text = update.text, update.carriesAssistantText {
                switch update.updateKind {
                case .assistantTextSnapshot:
                    assistant = text
                default:
                    assistant += text
                }
            }

            if update.updateKind == .thought, let text = update.text {
                thought += text
            }

            for plan in update.plans + [update.plan].compactMap({ $0 }) {
                if let index = plans.firstIndex(where: { $0.planID == plan.planID }) {
                    plans[index] = plan
                } else {
                    plans.append(plan)
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
        self.thoughtText = thought
        self.plans = plans
        self.toolStates = tools
        self.permissionStates = permissions
        self.terminalUpdate = terminal
        self.isTerminal = terminal != nil
        self.failed = terminal?.isTerminalFailure ?? false
    }
}
