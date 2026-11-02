// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Hosts the `me.atkn.gnostic.timeline.status` unary Call/Return operation.
public struct TimelineStatusProvider: Sendable {
    public static let statusOperation = "me.atkn.gnostic.timeline.status"

    public typealias StatusExecutor = @Sendable (TimelineStatusRequest) async throws -> TimelineStatus

    private let executor: StatusExecutor

    public init(execute: @escaping StatusExecutor) {
        self.executor = execute
    }

    public func handle(parameters: String?) async throws -> CallHandlerResult {
        if let failure = GnosticCallHandling.protocolFailure(
            parameters,
            invalidReasonCode: "invalidTimelineStatusPayload",
            invalidMessage: "Invalid timeline.status payload"
        ) {
            return failure
        }
        guard let request = GnosticCallHandling.decode(TimelineStatusRequest.self, from: parameters) else {
            return .failure(code: 400, reasonCode: "invalidTimelineStatusPayload", message: "Invalid timeline.status payload")
        }
        return try await GnosticCallHandling.run(
            fallbackReasonCode: "internalError",
            fallbackMessage: "The timeline status operation failed."
        ) {
            let status = try await executor(request)
            try GnosticProtocol.validate(status.protocolMajor)
            return try .encoded(status, context: "timeline.status result")
        }
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.statusOperation, context: context) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }
}
