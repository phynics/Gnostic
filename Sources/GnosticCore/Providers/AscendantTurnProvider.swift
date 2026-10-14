// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// The wire payload for a remote Ascendant Turn.
public struct AscendantTurnRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let message: String
    public let timelineID: UUID
    public let clientTurnID: String?

    public init(message: String, timelineID: UUID, clientTurnID: String? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.message = message
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, message, timelineID, clientTurnID }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(try GnosticWirePayload.canonicalTurnMessage(message), forKey: .message)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encodeIfPresent(clientTurnID, forKey: .clientTurnID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        message = try GnosticWirePayload.canonicalTurnMessage(try container.decode(String.self, forKey: .message))
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try container.decodeIfPresent(String.self, forKey: .clientTurnID).map {
            try GnosticWirePayload.canonicalClientTurnID($0)
        }
    }
}

/// The wire result of a remote Ascendant Turn.
public struct AscendantTurnResult: Codable, Sendable {
    public let protocolMajor: Int
    public let clientTurnID: String?
    public let text: String
    public let replayed: Bool

    public init(clientTurnID: String? = nil, text: String, replayed: Bool = false, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.clientTurnID = clientTurnID
        self.text = GnosticWirePayload.prefix(text, maximumBytes: GnosticWirePayload.maximumTurnResultTextBytes)
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor
        case clientTurnID
        case text
        case replayed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        if let clientTurnID {
            try container.encode(try GnosticWirePayload.canonicalClientTurnID(clientTurnID), forKey: .clientTurnID)
        }
        try container.encode(text, forKey: .text)
        try container.encode(replayed, forKey: .replayed)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        clientTurnID = try container.decodeIfPresent(String.self, forKey: .clientTurnID).map {
            try GnosticWirePayload.canonicalClientTurnID($0)
        }
        text = GnosticWirePayload.prefix(
            try container.decode(String.self, forKey: .text),
            maximumBytes: GnosticWirePayload.maximumTurnResultTextBytes
        )
        replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}

/// Hosts the `me.atkn.gnostic.ascendant.turn` unary Call/Return operation.
///
/// A thin wire adapter: decodes an `AscendantTurnRequest`, invokes the injected
/// turn closure (owned by the serve runtime), and encodes the result —
/// mirroring `WorkspaceProvider`'s contract.
public struct AscendantTurnProvider: Sendable {
    public static let turnOperation = "me.atkn.gnostic.ascendant.turn"
    public static let cancelOperation = "me.atkn.gnostic.ascendant.turn.cancel"
    public static let replayOperation = "me.atkn.gnostic.ascendant.turn.replay"
    public static let updateChannel = "me.atkn.gnostic.ascendant.turn.update"

    public typealias TurnExecutor = @Sendable (AscendantTurnRequest) async throws -> AscendantTurnResult
    public typealias TurnCancellation = @Sendable (AscendantTurnCancellationRequest) async -> Bool

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
        case turnOperation: "invalidAscendantTurnPayload"
        case replayOperation: "invalidAscendantTurnReplayPayload"
        default: "invalidAscendantTurnCancellationPayload"
        }
    }

    private static func invalidMessage(for operation: String) -> String {
        switch operation {
        case turnOperation: "Invalid ascendant.turn payload"
        case replayOperation: "Invalid ascendant.turn.replay payload"
        default: "Invalid ascendant.turn.cancel payload"
        }
    }

    private func handleTurn(_ parameters: String?) async throws -> CallHandlerResult {
        switch GnosticCallHandling.decode(
            AscendantTurnRequest.self,
            from: parameters,
            invalidReasonCode: "invalidAscendantTurnPayload",
            invalidMessage: "Invalid ascendant.turn payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            return try await GnosticCallHandling.run(
                fallbackReasonCode: "internalError",
                fallbackMessage: "The ascendant turn failed."
            ) {
                // The Turn ledger owns every replay update. The coordinator
                // records the terminal outcome and its bounded update before it
                // returns the result, so this adapter only maps values to the
                // wire.
                let executedResult = try await executor(request)
                let result = AscendantTurnResult(
                    clientTurnID: request.clientTurnID ?? executedResult.clientTurnID,
                    text: executedResult.text,
                    replayed: executedResult.replayed,
                    protocolMajor: executedResult.protocolMajor
                )
                try GnosticProtocol.validate(result.protocolMajor)
                return try .encoded(result, context: "ascendant.turn result")
            }
        }
    }

    private func handleReplay(_ parameters: String?) async throws -> CallHandlerResult {
        guard let replayStore else {
            return .failure(code: 400, reasonCode: "replayUnavailable", message: "Replay is not configured for this provider.")
        }
        switch GnosticCallHandling.decode(
            AscendantTurnReplayRequest.self,
            from: parameters,
            invalidReasonCode: "invalidAscendantTurnReplayPayload",
            invalidMessage: "Invalid ascendant.turn.replay payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            return try await GnosticCallHandling.run(
                fallbackReasonCode: "internalError",
                fallbackMessage: "The ascendant turn replay failed."
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
                return try .encoded(replay, context: "ascendant.turn.replay result")
            }
        }
    }

    private func handleCancellation(_ parameters: String?) async throws -> CallHandlerResult {
        switch GnosticCallHandling.decode(
            AscendantTurnCancellationRequest.self,
            from: parameters,
            invalidReasonCode: "invalidAscendantTurnCancellationPayload",
            invalidMessage: "Invalid ascendant.turn.cancel payload",
            identifierReasonCode: "invalidClientTurnID",
            overBudgetReasonCode: "promptTooLarge"
        ) {
        case let .rejected(failure):
            return failure
        case let .value(request):
            let cancelled = await cancellation(request)
            return try .encoded(
                AscendantTurnCancellationResult(cancelled: cancelled),
                context: "ascendant.turn.cancel result"
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
        let data = try GnosticWirePayload.encode(event, context: "ascendant.turn.update event")
        guard let privateData = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return try ChannelEvent.with(
            object: CoatyObject(
                coreType: .coatyObject,
                objectType: CoatyObject.objectType,
                objectId: CoatyUUID(),
                name: "Gnostic Ascendant turn update"
            ),
            channelId: updateChannel,
            privateData: privateData
        )
    }
}

public struct AscendantTurnReplayRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String
    public let message: String?
    public let afterSequence: Int

    public init(timelineID: UUID, clientTurnID: String, message: String? = nil, afterSequence: Int = 0, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.message = message
        self.afterSequence = afterSequence
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID, message, afterSequence }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encode(clientTurnID, forKey: .clientTurnID)
        if let message {
            try container.encode(
                try GnosticWirePayload.canonicalTurnMessage(message, context: "ascendant.turn.replay message"),
                forKey: .message
            )
        }
        try container.encode(afterSequence, forKey: .afterSequence)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try GnosticWirePayload.canonicalClientTurnID(
            container.decode(String.self, forKey: .clientTurnID)
        )
        message = try container.decodeIfPresent(String.self, forKey: .message).map {
            try GnosticWirePayload.canonicalTurnMessage($0, context: "ascendant.turn.replay message")
        }
        afterSequence = try container.decodeIfPresent(Int.self, forKey: .afterSequence) ?? 0
    }
}

/// Identifies the admitted Turn that an explicit client cancellation targets.
public struct AscendantTurnCancellationRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let clientTurnID: String

    public init(timelineID: UUID, clientTurnID: String, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try GnosticWirePayload.canonicalClientTurnID(
            container.decode(String.self, forKey: .clientTurnID)
        )
    }
}

public struct AscendantTurnCancellationResult: Codable, Sendable {
    public let protocolMajor: Int
    public let cancelled: Bool

    public init(cancelled: Bool, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.cancelled = cancelled
    }
}
