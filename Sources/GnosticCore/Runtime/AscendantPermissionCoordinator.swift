// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Logging
import PKContracts

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
        let approved = await coordinator.request(BackendPermissionRequest(
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
        let clientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID
        let continuation: AsyncStream<Bool>.Continuation
    }

    private let updates: AscendantTurnUpdateStore
    private let logger: Logger
    private var pending: [String: Pending] = [:]
    private var acceptingResponses = true

    public init(updates: AscendantTurnUpdateStore) {
        self.updates = updates
        self.logger = ServeLogging.makeLogger(label: "\(ServeLogging.subsystem).permission")
    }

    public var pendingCount: Int { pending.count }

    public func request(_ request: AscendantPermissionRequest) async -> Bool {
        guard acceptingResponses else { return false }
        guard let clientTurnID = try? await updates.validatedClientTurnID(request.clientTurnID) else {
            logger.warning("permission request rejected: invalid client turn ID")
            return false
        }
        do {
            try await updates.start(timelineID: request.timelineID, clientTurnID: clientTurnID)
        } catch {
            logger.warning("permission request rejected: update retention capacity is full")
            return false
        }
        guard pending[request.correlationID] == nil else { return false }
        let (decisions, continuation) = AsyncStream<Bool>.makeStream()
        pending[request.correlationID] = Pending(request: request, clientTurnID: clientTurnID, continuation: continuation)
        await append(request, clientTurnID: clientTurnID, status: .pending)
        var iterator = decisions.makeAsyncIterator()
        return await iterator.next() ?? false
    }

    @discardableResult
    public func respond(
        correlationID: String,
        timelineID: UUID,
        clientTurnID: String,
        approved: Bool
    ) async -> Bool {
        guard acceptingResponses else { return false }
        guard let responseClientTurnID = try? await updates.validatedClientTurnID(clientTurnID) else {
            logger.warning("permission response rejected: invalid client turn ID")
            return false
        }
        guard let value = pending[correlationID],
              value.request.timelineID == timelineID,
              value.request.clientTurnID == responseClientTurnID.rawValue else { return false }
        pending[correlationID] = nil
        await append(value.request, clientTurnID: value.clientTurnID, status: approved ? .selected : .denied)
        await updates.finish(timelineID: value.request.timelineID, clientTurnID: value.clientTurnID)
        value.continuation.yield(approved)
        value.continuation.finish()
        return true
    }

    public func denyAll(reason: AscendantPermissionStatus) async {
        acceptingResponses = false
        let values = Array(pending.values)
        pending.removeAll()
        for value in values {
            await append(value.request, clientTurnID: value.clientTurnID, status: reason)
            await updates.finish(timelineID: value.request.timelineID, clientTurnID: value.clientTurnID)
            value.continuation.yield(false)
            value.continuation.finish()
        }
    }

    private func append(
        _ request: AscendantPermissionRequest,
        clientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID,
        status: AscendantPermissionStatus
    ) async {
        do {
            _ = try await updates.append(
            timelineID: request.timelineID,
            clientTurnID: clientTurnID,
            kind: AscendantTurnUpdateKind.permissionState.rawValue,
            permissionState: AscendantPermissionState(
                correlationID: request.correlationID,
                toolCallID: request.toolCallID,
                title: request.title,
                status: status
            )
        )
        } catch {
            logger.warning("permission update rejected: update retention capacity is full")
        }
    }
}

extension AscendantPermissionCoordinator: AscendantBackendPermissionService {
    public func request(_ request: BackendPermissionRequest) async -> Bool {
        await self.request(AscendantPermissionRequest(
            correlationID: request.correlationID,
            timelineID: request.timelineID,
            clientTurnID: request.clientTurnID,
            toolCallID: request.toolCallID,
            title: request.title
        ))
    }
}
