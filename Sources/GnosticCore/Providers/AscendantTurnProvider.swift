// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Hosts the `me.atkn.gnostic.turn` unary Call/Return operation.
///
/// A thin wire adapter: decodes an `TurnRequest`, invokes the injected
/// turn closure (owned by the serve runtime), and encodes the result —
/// mirroring `WorkspaceProvider`'s contract.
public struct AscendantTurnProvider: Sendable {
    public static let turnOperation = "me.atkn.gnostic.turn"
    public static let cancelOperation = "me.atkn.gnostic.turn.cancel"
    public static let replayOperation = "me.atkn.gnostic.turn.replay"
    public static let updateChannel = "me.atkn.gnostic.turn.update"

    public typealias TurnExecutor = @Sendable (TurnRequest) async throws -> TurnResult
    public typealias TurnCancellation = @Sendable (TurnCancellationRequest) async -> Bool

    private let executor: TurnExecutor
    private let cancellation: TurnCancellation
    private let replayStore: AscendantTurnUpdateStore?
    private let isAvailable: @Sendable () async -> Bool

    public init(
        execute: @escaping TurnExecutor,
        cancel: @escaping TurnCancellation = { _ in false },
        replayStore: AscendantTurnUpdateStore? = nil,
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.executor = execute
        cancellation = cancel
        self.replayStore = replayStore
        self.isAvailable = isAvailable
    }

    public func handle(operation: String, parameters: String?) async throws -> CallHandlerResult {
        guard [Self.turnOperation, Self.replayOperation, Self.cancelOperation].contains(operation) else {
            return .failure(code: 404, reasonCode: "unknownTurnOperation", message: "Unknown turn operation")
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
            return try await handleTurn(parameters)
        case Self.replayOperation:
            return try await handleReplay(parameters)
        default:
            return try await handleCancellation(parameters)
        }
    }

    private static func invalidReasonCode(for operation: String) -> String {
        switch operation {
        case turnOperation: "invalidTurnPayload"
        case replayOperation: "invalidTurnReplayPayload"
        default: "invalidTurnCancellationPayload"
        }
    }

    private static func invalidMessage(for operation: String) -> String {
        switch operation {
        case turnOperation: "Invalid turn payload"
        case replayOperation: "Invalid turn.replay payload"
        default: "Invalid turn.cancel payload"
        }
    }

    private func handleTurn(_ parameters: String?) async throws -> CallHandlerResult {
        switch GnosticCallHandling.decode(
            TurnRequest.self,
            from: parameters,
            invalidReasonCode: "invalidTurnPayload",
            invalidMessage: "Invalid turn payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            return try await GnosticCallHandling.run(
                fallbackReasonCode: "internalError",
                fallbackMessage: "The Turn failed."
            ) {
                // The Turn ledger owns every replay update. The coordinator
                // records the terminal outcome and its bounded update before it
                // returns the result, so this adapter only maps values to the
                // wire.
                let executedResult = try await executor(request)
                let result = TurnResult(
                    clientTurnID: request.clientTurnID ?? executedResult.clientTurnID,
                    text: executedResult.text,
                    replayed: executedResult.replayed,
                    protocolMajor: executedResult.protocolMajor
                )
                try GnosticProtocol.validate(result.protocolMajor)
                return try .encoded(result, context: "turn result")
            }
        }
    }

    private func handleReplay(_ parameters: String?) async throws -> CallHandlerResult {
        guard let replayStore else {
            return .failure(code: 400, reasonCode: "replayUnavailable", message: "Replay is not configured for this provider.")
        }
        switch GnosticCallHandling.decode(
            TurnReplayRequest.self,
            from: parameters,
            invalidReasonCode: "invalidTurnReplayPayload",
            invalidMessage: "Invalid turn.replay payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            return try await GnosticCallHandling.run(
                fallbackReasonCode: "internalError",
                fallbackMessage: "The Turn replay failed."
            ) {
                let replay = try await replayStore.replay(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID,
                    message: request.message,
                    afterSequence: request.afterSequence
                )
                if replay.conflict {
                    return .failure(code: 409, reasonCode: "turnConflict", message: "clientTurnID was already used with different content")
                }
                try GnosticProtocol.validate(replay.protocolMajor)
                return try .encoded(replay, context: "turn.replay result")
            }
        }
    }

    private func handleCancellation(_ parameters: String?) async throws -> CallHandlerResult {
        switch GnosticCallHandling.decode(
            TurnCancellationRequest.self,
            from: parameters,
            invalidReasonCode: "invalidTurnCancellationPayload",
            invalidMessage: "Invalid turn.cancel payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            let cancelled = await cancellation(request)
            return try .encoded(
                TurnCancellationResult(cancelled: cancelled),
                context: "turn.cancel result"
            )
        }
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        try await GnosticCallHandling.register(
            operations: [Self.turnOperation, Self.replayOperation, Self.cancelOperation],
            on: communication,
            context: context
        ) { [self] operation, parameters in
            try await handle(operation: operation, parameters: parameters)
        }
    }

    public static func updateEvent(_ event: AscendantTurnUpdateStore.Event) throws -> ChannelEvent {
        let data = try GnosticWirePayload.encode(event, context: "turn.update event")
        guard let privateData = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return try ChannelEvent.with(
            object: CoatyObject(
                coreType: .coatyObject,
                objectType: CoatyObject.objectType,
                objectId: CoatyUUID(),
                name: "Gnostic turn update"
            ),
            channelId: updateChannel,
            privateData: privateData
        )
    }
}
