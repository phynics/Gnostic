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

/// The former spelling of ``BackendPermissionRequest``. The two types had
/// identical stored properties and one meaning.
@available(*, deprecated, renamed: "BackendPermissionRequest")
public typealias AscendantPermissionRequest = BackendPermissionRequest

public actor AscendantPermissionCoordinator {
    private struct Pending {
        let request: BackendPermissionRequest
        let clientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID
        let continuation: AsyncStream<AscendantPermissionDecision>.Continuation
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

    /// Puts one permission request to the client and awaits its decision.
    ///
    /// - Parameter request: The correlated request to mediate.
    /// - Returns: ``AscendantPermissionDecision/approved`` or
    ///   ``AscendantPermissionDecision/denied`` when the client answered, and
    ///   ``AscendantPermissionDecision/unavailable(reason:)`` when the host
    ///   could not ask. A host failure is never reported as a denial.
    public func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
        guard acceptingResponses else {
            return .unavailable(reason: "permissionMediationStopped")
        }
        guard let clientTurnID = try? await updates.validatedClientTurnID(request.clientTurnID) else {
            logger.warning("permission request rejected: invalid client turn ID")
            return .unavailable(reason: "invalidClientTurnID")
        }
        do {
            try await updates.start(timelineID: request.timelineID, clientTurnID: clientTurnID)
        } catch {
            logger.warning("permission request rejected: update retention capacity is full")
            return .unavailable(reason: "retentionCapacityExceeded")
        }
        guard pending[request.correlationID] == nil else {
            return .unavailable(reason: "duplicateCorrelationID")
        }
        let (decisions, continuation) = AsyncStream<AscendantPermissionDecision>.makeStream()
        pending[request.correlationID] = Pending(request: request, clientTurnID: clientTurnID, continuation: continuation)
        await append(request, clientTurnID: clientTurnID, status: .pending)
        var iterator = decisions.makeAsyncIterator()
        return await iterator.next() ?? .unavailable(reason: "decisionStreamEnded")
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
        value.continuation.yield(approved ? .approved : .denied)
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
            value.continuation.yield(.unavailable(reason: reason.rawValue))
            value.continuation.finish()
        }
    }

    private func append(
        _ request: BackendPermissionRequest,
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

extension AscendantPermissionCoordinator: AscendantBackendPermissionService {}
