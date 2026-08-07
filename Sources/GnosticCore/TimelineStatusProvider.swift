// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// The wire payload requesting timeline state.
public struct TimelineStatusRequest: Codable, Sendable {
    public let timelineID: UUID

    public init(timelineID: UUID) {
        self.timelineID = timelineID
    }
}

/// The wire result describing a timeline's attachment state.
public struct TimelineStatus: Codable, Sendable {
    public let timelineID: UUID
    public let title: String
    public let attachedWorkspaceIDs: [UUID]
    public let isArchived: Bool
    public let isPrivate: Bool

    public init(
        timelineID: UUID,
        title: String,
        attachedWorkspaceIDs: [UUID],
        isArchived: Bool = false,
        isPrivate: Bool = false
    ) {
        self.timelineID = timelineID
        self.title = title
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.isArchived = isArchived
        self.isPrivate = isPrivate
    }
}

/// Hosts the `me.atkn.gnostic.timeline.status` unary Call/Return operation.
public struct TimelineStatusProvider: Sendable {
    public static let statusOperation = "me.atkn.gnostic.timeline.status"

    public typealias StatusExecutor = @Sendable (TimelineStatusRequest) async throws -> TimelineStatus

    private let executor: StatusExecutor

    public init(execute: @escaping StatusExecutor) {
        self.executor = execute
    }

    public func handle(parameters: String?) async throws -> CallHandlerResult {
        guard let parameters,
              let request = try? JSONDecoder().decode(TimelineStatusRequest.self, from: Data(parameters.utf8)) else {
            return .failure(code: 400, message: "Invalid timeline.status payload")
        }
        do {
            let status = try await executor(request)
            let encoded = try JSONEncoder().encode(status)
            return .success(result: String(decoding: encoded, as: UTF8.self))
        } catch {
            return .failure(code: 500, message: String(describing: error))
        }
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.statusOperation) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }
}