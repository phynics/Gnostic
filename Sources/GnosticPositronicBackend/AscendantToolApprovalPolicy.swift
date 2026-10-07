// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import PositronicKit

/// Bridges Gnostic's mediated permission decision to PositronicKit's tool gate.
///
/// `ToolApprovalDecision` is binary, so an
/// ``AscendantPermissionDecision/unavailable(reason:)`` outcome necessarily
/// becomes `.deny` at this boundary: a tool whose approval could not be
/// obtained must not run. The reason is not lost -- it is logged by
/// ``AscendantPermissionCoordinator`` and, whenever a turn entry exists,
/// recorded on the replayable permission state -- but callers that need to
/// tell a host failure from a client refusal must read the decision from
/// ``AscendantBackendPermissionService`` rather than infer it from a denied
/// tool call.
public struct AscendantToolApprovalPolicy: ToolApprovalPolicy {
    private let coordinator: any AscendantBackendPermissionService

    public init(coordinator: any AscendantBackendPermissionService) {
        self.coordinator = coordinator
    }

    public func requestApproval(
        tool: AnyTool,
        arguments _: [String: AnyCodable]
    ) async -> ToolApprovalDecision {
        guard let context = AscendantTurnPermissionContext.current else { return .deny }
        let correlationID = UUID().uuidString.lowercased()
        let decision = await coordinator.requestApproval(for: BackendPermissionRequest(
            correlationID: correlationID,
            timelineID: context.timelineID,
            clientTurnID: context.clientTurnID,
            toolCallID: "permission:\(correlationID)",
            title: tool.name
        ))
        return decision.isApproved ? .approve : .deny
    }
}
