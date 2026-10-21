// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Bridges Timeline-owned Turn operations across the Axoloty Call/Return boundary.
public struct TimelineTurnProvider: Sendable {
    public static let turnOperation = "me.atkn.gnostic.timeline.turn"
    public static let cancelOperation = "me.atkn.gnostic.timeline.turn.cancel"
    public static let replayOperation = "me.atkn.gnostic.timeline.turn.replay"
    public static let updateChannel = "me.atkn.gnostic.timeline.turn.update"
    public static let permissionOperation = "me.atkn.gnostic.timeline.permission"
    public static let permissionRespondOperation = "me.atkn.gnostic.timeline.permission.respond"
    public static let permissionResponseChannel = "me.atkn.gnostic.timeline.permission.response"

    /// Dispatches `session/prompt` to the session's Runtime and returns the
    /// confirmed `messageId`. The provider must never synthesize this value.
    public typealias PromptDispatcher = @Sendable (TimelineTurnEnvelope) async throws -> String

    /// Publishes one streamed turn update to the consumer of the update channel.
    public typealias UpdatePublisher = @Sendable (TimelineTurnUpdate) async -> Void

    private let coordinator: TimelineTurnCoordinator
    private let promptDispatcher: PromptDispatcher
    private let isAvailable: @Sendable () async -> Bool

    public init(
        coordinator: TimelineTurnCoordinator,
        promptDispatcher: @escaping PromptDispatcher,
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.coordinator = coordinator
        self.promptDispatcher = promptDispatcher
        self.isAvailable = isAvailable
    }

    public func handle(
        operation: String,
        parameters: String?,
        publishUpdate: UpdatePublisher? = nil
    ) async throws -> CallHandlerResult {
        guard [Self.turnOperation, Self.replayOperation, Self.cancelOperation].contains(operation) else {
            return .failure(code: 404, reasonCode: "unknownTimelineOperation", message: "Unknown timeline operation")
        }
        guard await isAvailable() else {
            return .failure(code: 503, reasonCode: "notRunning", message: "The node runtime is not running.")
        }
        if let failure = GnosticCallHandling.protocolFailure(
            parameters,
            invalidReasonCode: Self.invalidReasonCode(for: operation),
            invalidMessage: Self.invalidMessage(for: operation)
        ) {
            return failure
        }
        switch operation {
        case Self.turnOperation:
            return try await handleTurn(parameters, publishUpdate: publishUpdate)
        case Self.replayOperation:
            return try await handleReplay(parameters)
        default:
            return try await handleCancellation(parameters)
        }
    }

    private static func invalidReasonCode(for operation: String) -> String {
        switch operation {
        case turnOperation: "invalidTimelineTurnPayload"
        case replayOperation: "invalidTimelineTurnReplayPayload"
        default: "invalidTimelineTurnCancellationPayload"
        }
    }

    private static func invalidMessage(for operation: String) -> String {
        switch operation {
        case turnOperation: "Invalid timeline.turn payload"
        case replayOperation: "Invalid timeline.turn.replay payload"
        default: "Invalid timeline.turn.cancel payload"
        }
    }

    private func handleTurn(_ parameters: String?, publishUpdate: UpdatePublisher?) async throws -> CallHandlerResult {
        switch GnosticCallHandling.decode(
            TimelineTurnEnvelope.self,
            from: parameters,
            invalidReasonCode: "invalidTimelineTurnPayload",
            invalidMessage: "Invalid timeline.turn payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(envelope):
            do {
                let result = try await coordinator.execute(
                    envelope: envelope,
                    promptDispatch: promptDispatcher,
                    streamUpdates: publishUpdate
                )
                try GnosticProtocol.validate(result.protocolMajor)
                return try .encoded(result, context: "timeline.turn result")
            } catch let error as TimelineTurnError {
                switch error {
                case .timelineBusy:
                    return .failure(
                        code: -32001,
                        reasonCode: "timelineBusy",
                        message: "Timeline is busy",
                        retryable: true
                    )
                case let .conflictingPayload(id):
                    return .failure(
                        code: -32602,
                        reasonCode: "conflictingPayload",
                        message: "Conflicting prompt payload under identical clientTurnID '\(id)'",
                        retryable: false
                    )
                case .insertionUnknown:
                    return .failure(
                        code: -32000,
                        reasonCode: "insertionUnknown",
                        message: "Prompt dispatch response lost or ambiguous; turn entered insertionUnknown",
                        retryable: false
                    )
                case .turnCancelled:
                    return .failure(
                        code: -32800,
                        reasonCode: "turnCancelled",
                        message: "Timeline turn was cancelled",
                        retryable: false
                    )
                case let .failed(code, message):
                    return .failure(code: 500, reasonCode: code, message: message, retryable: false)
                }
            } catch {
                return .failure(code: 500, reasonCode: "internalError", message: error.localizedDescription)
            }
        }
    }

    private func handleReplay(_ parameters: String?) async throws -> CallHandlerResult {
        switch GnosticCallHandling.decode(
            TimelineTurnReplayRequest.self,
            from: parameters,
            invalidReasonCode: "invalidTimelineTurnReplayPayload",
            invalidMessage: "Invalid timeline.turn.replay payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            guard let replay = await coordinator.replay(timelineID: request.timelineID, clientTurnID: request.clientTurnID) else {
                return .failure(code: 404, reasonCode: "turnNotFound", message: "No turn found to replay.")
            }
            try GnosticProtocol.validate(replay.protocolMajor)
            return try .encoded(replay, context: "timeline.turn.replay result")
        }
    }

    private func handleCancellation(_ parameters: String?) async throws -> CallHandlerResult {
        switch GnosticCallHandling.decode(
            TimelineTurnCancellationRequest.self,
            from: parameters,
            invalidReasonCode: "invalidTimelineTurnCancellationPayload",
            invalidMessage: "Invalid timeline.turn.cancel payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            let cancelled = await coordinator.cancel(timelineID: request.timelineID, clientTurnID: request.clientTurnID)
            let result = TimelineTurnCancellationResult(
                timelineID: request.timelineID,
                clientTurnID: request.clientTurnID,
                cancelled: cancelled,
                protocolMajor: GnosticProtocol.currentMajor
            )
            return try .encoded(result, context: "timeline.turn.cancel result")
        }
    }

    /// Creates a Channel event carrying one streamed turn update.
    public static func updateEvent(_ update: TimelineTurnUpdate) throws -> ChannelEvent {
        let data = try GnosticWirePayload.encode(update, context: "timeline.turn.update event")
        guard let privateData = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        let marker = CoatyObject(
            coreType: .coatyObject,
            objectType: CoatyObject.objectType,
            objectId: CoatyUUID(),
            name: "Gnostic timeline turn update"
        )
        return try ChannelEvent.with(object: marker, channelId: updateChannel, privateData: privateData)
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        // Streamed turn updates travel one way over the update channel, so the
        // consumer sees them while the Turn is still active.
        let publishUpdate: UpdatePublisher = { update in
            guard let event = try? Self.updateEvent(update) else { return }
            await communication.publishChannel(event)
        }
        return try await GnosticCallHandling.register(
            operations: [Self.turnOperation, Self.replayOperation, Self.cancelOperation],
            on: communication,
            context: context
        ) { [self] operation, parameters in
            try await handle(operation: operation, parameters: parameters, publishUpdate: publishUpdate)
        }
    }
}
