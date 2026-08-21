// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts

/// The wire payload requesting timeline state.
public struct TimelineStatusRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID

    public init(timelineID: UUID, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
    }
}

/// The wire result describing a timeline's attachment state.
public struct TimelineStatus: Codable, Sendable {
    public let protocolMajor: Int
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
        isPrivate: Bool = false,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.title = title
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.isArchived = isArchived
        self.isPrivate = isPrivate
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, timelineID, title, attachedWorkspaceIDs, isArchived, isPrivate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        title = try container.decode(String.self, forKey: .title)
        attachedWorkspaceIDs = try container.decode([UUID].self, forKey: .attachedWorkspaceIDs)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
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
        do {
            try GnosticProtocol.validatePayload(parameters)
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch {
            return failure(code: 400, reasonCode: "invalidTimelineStatusPayload", message: "Invalid timeline.status payload")
        }
        guard let parameters,
              let request = try? JSONDecoder().decode(TimelineStatusRequest.self, from: Data(parameters.utf8)) else {
            return failure(code: 400, reasonCode: "invalidTimelineStatusPayload", message: "Invalid timeline.status payload")
        }
        do {
            let status = try await executor(request)
            try GnosticProtocol.validate(status.protocolMajor)
            let encoded = try JSONEncoder().encode(status)
            return .success(result: String(decoding: encoded, as: UTF8.self))
        } catch let error as NodeRuntimeError {
            return failure(code: error.statusCode, reasonCode: error.reasonCode, message: error.localizedDescription)
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch {
            return failure(code: 500, reasonCode: "internalError", message: String(describing: error))
        }
    }

    private func failure(code: Int, reasonCode: String, message: String) -> CallHandlerResult {
        .failure(code: code, message: GnosticProtocol.failureMessage(reasonCode: reasonCode, message: message))
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.statusOperation, context: context) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }
}
