// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Bridges host-mediated permission operations across the Axoloty Call/Return boundary.
public struct TimelinePermissionProvider: Sendable {
    public static let permissionOperation = "me.atkn.gnostic.timeline.permission"
    public static let responseOperation = "me.atkn.gnostic.timeline.permission.respond"
    public static let responseChannel = "me.atkn.gnostic.timeline.permission.response"

    public typealias PermissionResolver = @Sendable (TimelinePermissionResponse) async -> Bool

    private let resolver: PermissionResolver
    private let isAvailable: @Sendable () async -> Bool

    public init(
        resolve: @escaping PermissionResolver,
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.resolver = resolve
        self.isAvailable = isAvailable
    }

    public func handle(operation: String, parameters: String?) async throws -> CallHandlerResult {
        guard operation == Self.responseOperation else {
            return .failure(code: 404, reasonCode: "unknownPermissionOperation", message: "Unknown permission operation")
        }
        guard await isAvailable() else {
            return .failure(code: 503, reasonCode: "notRunning", message: "The node runtime is not running.")
        }
        if let failure = GnosticCallHandling.protocolFailure(
            parameters,
            invalidReasonCode: "invalidTimelinePermissionResponsePayload",
            invalidMessage: "Invalid timeline.permission.respond payload"
        ) {
            return failure
        }

        switch GnosticCallHandling.decode(
            TimelinePermissionResponse.self,
            from: parameters,
            invalidReasonCode: "invalidTimelinePermissionResponsePayload",
            invalidMessage: "Invalid timeline.permission.respond payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(response):
            let accepted = await resolver(response)
            let result = TimelinePermissionMutationResult(
                correlationID: response.correlationID,
                accepted: accepted,
                protocolMajor: GnosticProtocol.currentMajor
            )
            return try .encoded(result, context: "timeline.permission.respond result")
        }
    }
}
