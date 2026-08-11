// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared

public enum AscendantTurnPermissionContext {
    public struct Value: Sendable {
        public let timelineID: UUID
        public let clientTurnID: String

        public init(timelineID: UUID, clientTurnID: String) {
            self.timelineID = timelineID
            self.clientTurnID = clientTurnID
        }
    }

    @TaskLocal public static var current: Value?
}

public struct AscendantToolApprovalPolicy: ToolApprovalPolicy {
    private let coordinator: AscendantPermissionCoordinator

    public init(coordinator: AscendantPermissionCoordinator) {
        self.coordinator = coordinator
    }

    public func requestApproval(
        tool: AnyTool,
        arguments _: [String: AnyCodable]
    ) async -> ToolApprovalDecision {
        guard let context = AscendantTurnPermissionContext.current else { return .deny }
        let correlationID = UUID().uuidString.lowercased()
        let approved = await coordinator.request(AscendantPermissionRequest(
            correlationID: correlationID,
            timelineID: context.timelineID,
            clientTurnID: context.clientTurnID,
            toolCallID: "permission:\(correlationID)",
            title: tool.name
        ))
        return approved ? .approve : .deny
    }
}

public struct AscendantPermissionRequest: Sendable, Equatable {
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let toolCallID: String
    public let title: String

    public init(
        correlationID: String,
        timelineID: UUID,
        clientTurnID: String,
        toolCallID: String,
        title: String
    ) {
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.toolCallID = toolCallID
        self.title = title
    }
}

public actor AscendantPermissionCoordinator {
    private struct Pending {
        let request: AscendantPermissionRequest
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let updates: AscendantTurnUpdateStore
    private var pending: [String: Pending] = [:]

    public init(updates: AscendantTurnUpdateStore) {
        self.updates = updates
    }

    public var pendingCount: Int { pending.count }

    public func request(_ request: AscendantPermissionRequest) async -> Bool {
        guard pending[request.correlationID] == nil else { return false }
        return await withCheckedContinuation { continuation in
            pending[request.correlationID] = Pending(request: request, continuation: continuation)
            Task { await self.append(request, status: "pending") }
        }
    }

    @discardableResult
    public func respond(
        correlationID: String,
        timelineID: UUID,
        clientTurnID: String,
        approved: Bool
    ) async -> Bool {
        guard let value = pending[correlationID],
              value.request.timelineID == timelineID,
              value.request.clientTurnID == clientTurnID else { return false }
        pending[correlationID] = nil
        await append(value.request, status: approved ? "selected" : "denied")
        value.continuation.resume(returning: approved)
        return true
    }

    public func denyAll(reason: String) async {
        let values = Array(pending.values)
        pending.removeAll()
        for value in values {
            await append(value.request, status: reason)
            value.continuation.resume(returning: false)
        }
    }

    private func append(_ request: AscendantPermissionRequest, status: String) async {
        _ = await updates.append(
            timelineID: request.timelineID,
            clientTurnID: request.clientTurnID,
            kind: "permission_state",
            permissionState: AscendantPermissionState(
                correlationID: request.correlationID,
                toolCallID: request.toolCallID,
                title: request.title,
                status: status
            )
        )
    }
}
