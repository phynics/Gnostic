// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import Logging

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
