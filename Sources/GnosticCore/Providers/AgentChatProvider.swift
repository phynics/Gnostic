// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts

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
        try container.encode(message, forKey: .message)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encodeIfPresent(clientTurnID, forKey: .clientTurnID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        message = GnosticWirePayload.prefix(try container.decode(String.self, forKey: .message), maximumBytes: GnosticWirePayload.maximumLabelBytes)
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
    public static let replayOperation = "me.atkn.gnostic.ascendant.turn.replay"
    public static let updateChannel = "me.atkn.gnostic.ascendant.turn.update"

    public typealias TurnExecutor = @Sendable (AscendantTurnRequest) async throws -> AscendantTurnResult

    private let executor: TurnExecutor
    private let replayStore: AscendantTurnUpdateStore?
    private let isAvailable: @Sendable () async -> Bool

    public init(
        execute: @escaping TurnExecutor,
        replayStore: AscendantTurnUpdateStore? = nil,
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.executor = execute
        self.replayStore = replayStore
        self.isAvailable = isAvailable
    }

    public func handle(parameters: String?) async throws -> CallHandlerResult {
        guard await isAvailable() else {
            return failure(code: 503, reasonCode: "notRunning", message: "The node runtime is not running.")
        }
        guard let parameters else {
            return .failure(code: GnosticProtocolError.missing.statusCode, message: GnosticProtocolError.missing.failureMessage)
        }
        let request: AscendantTurnRequest
        do {
            request = try JSONDecoder().decode(AscendantTurnRequest.self, from: Data(parameters.utf8))
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch let error as GnosticWirePayload.Error {
            if case .invalidIdentifier = error {
                return failure(code: 400, reasonCode: "invalidClientTurnID", message: error.localizedDescription)
            }
            return failure(code: 400, reasonCode: "invalidAscendantTurnPayload", message: "Invalid ascendant.turn payload")
        } catch {
            return failure(code: 400, reasonCode: "invalidAscendantTurnPayload", message: "Invalid ascendant.turn payload")
        }
        do {
            if let replayStore, let clientTurnID = request.clientTurnID {
                await replayStore.start(timelineID: request.timelineID, clientTurnID: clientTurnID, message: request.message)
            }
            let executedResult = try await executor(request)
            let result = AscendantTurnResult(
                clientTurnID: request.clientTurnID ?? executedResult.clientTurnID,
                text: executedResult.text,
                replayed: executedResult.replayed,
                protocolMajor: executedResult.protocolMajor
            )
            do {
                try GnosticProtocol.validate(result.protocolMajor)
            } catch let error as GnosticProtocolError {
                return .failure(code: error.statusCode, message: error.failureMessage)
            }
            if let replayStore, let clientTurnID = request.clientTurnID, !result.replayed {
                let replay = await replayStore.replay(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID
                )
                let streamed = replay.updates.contains {
                    $0.kind == "assistant_text" || $0.kind == "assistant_text_snapshot"
                }
                if !streamed {
                    _ = await replayStore.append(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID,
                        kind: "assistant_text",
                        text: result.text
                    )
                }
                _ = await replayStore.append(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID,
                    kind: "completion",
                    text: result.text,
                    terminal: true
                )
            }
            let encoded = try GnosticWirePayload.encode(result, context: "ascendant.turn result")
            return .success(result: String(decoding: encoded, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AscendantTurnError {
            let mapped = GnosticProtocol.publicFailure(
                for: error,
                fallbackCode: 500,
                fallbackReasonCode: "internalError",
                fallbackMessage: "The ascendant turn failed."
            )
            if let replayStore, let clientTurnID = request.clientTurnID,
               !isAdmissionOnlyError(error) {
                _ = await replayStore.append(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID,
                    kind: "error",
                    text: error.publicMessage,
                    terminal: true,
                    reasonCode: error.reasonCode,
                    statusCode: error.statusCode,
                    retryable: error.retryable
                )
            }
            return .failure(code: mapped.code, message: mapped.message)
        } catch let error as NodeRuntimeError {
            let mapped = GnosticProtocol.publicFailure(
                for: error,
                fallbackCode: 500,
                fallbackReasonCode: "internalError",
                fallbackMessage: "The ascendant turn failed."
            )
            if let replayStore, let clientTurnID = request.clientTurnID {
                _ = await replayStore.append(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID,
                    kind: "error",
                    text: error.publicMessage,
                    terminal: true,
                    reasonCode: error.reasonCode,
                    statusCode: error.statusCode
                )
            }
            return .failure(code: mapped.code, message: mapped.message)
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch {
            if let replayStore, let clientTurnID = request.clientTurnID {
                _ = await replayStore.append(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID,
                    kind: "error",
                    text: "The ascendant turn failed.",
                    terminal: true,
                    reasonCode: "internalError",
                    statusCode: 500
                )
            }
            let mapped = GnosticProtocol.publicFailure(
                for: error,
                fallbackCode: 500,
                fallbackReasonCode: "internalError",
                fallbackMessage: "The ascendant turn failed."
            )
            return .failure(code: mapped.code, message: mapped.message)
        }
    }

    private func isAdmissionOnlyError(_ error: AscendantTurnError) -> Bool {
        switch error {
        case .conflict, .replayUnavailable: return true
        case .failed, .terminal, .cancelled, .lifecycleUnusable, .backendUnavailable: return false
        }
    }

    public func handleReplay(parameters: String?) async throws -> CallHandlerResult {
        guard await isAvailable() else {
            return failure(code: 503, reasonCode: "notRunning", message: "The node runtime is not running.")
        }
        guard let replayStore else {
            return failure(code: 400, reasonCode: "replayUnavailable", message: "Replay is not configured for this provider.")
        }
        guard let parameters else {
            return .failure(code: GnosticProtocolError.missing.statusCode, message: GnosticProtocolError.missing.failureMessage)
        }
        let request: AscendantTurnReplayRequest
        do {
            request = try JSONDecoder().decode(AscendantTurnReplayRequest.self, from: Data(parameters.utf8))
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch let error as GnosticWirePayload.Error {
            if case .invalidIdentifier = error {
                return failure(code: 400, reasonCode: "invalidClientTurnID", message: error.localizedDescription)
            }
            return failure(code: 400, reasonCode: "invalidAscendantTurnReplayPayload", message: "Invalid ascendant.turn.replay payload")
        } catch {
            return failure(code: 400, reasonCode: "invalidAscendantTurnReplayPayload", message: "Invalid ascendant.turn.replay payload")
        }
        let replay = await replayStore.replay(
            timelineID: request.timelineID,
            clientTurnID: request.clientTurnID,
            message: request.message,
            afterSequence: request.afterSequence
        )
        if replay.conflict {
            return failure(code: 409, reasonCode: "turnConflict", message: "clientTurnID was already used with different content")
        }
        do {
            try GnosticProtocol.validate(replay.protocolMajor)
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        }
        let encoded = try GnosticWirePayload.encode(replay, context: "ascendant.turn.replay result")
        return .success(result: String(decoding: encoded, as: UTF8.self))
    }

    private func failure(code: Int, reasonCode: String, message: String, retryable: Bool = false) -> CallHandlerResult {
        .failure(
            code: code,
            message: GnosticProtocol.failureMessage(
                reasonCode: reasonCode,
                message: message,
                statusCode: code,
                retryable: retryable
            )
        )
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.turnOperation, context: context) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }

    @MainActor
    public func registerReplay(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.replayOperation, context: context) { [self] request in
            try await handleReplay(parameters: request.parameters)
        }
    }

    public static func updateEvent(_ event: AscendantTurnUpdateStore.Event) throws -> ChannelEvent {
        let data = try GnosticWirePayload.encode(event, context: "ascendant.turn.update event")
        guard let privateData = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return try ChannelEvent.with(
            object: CoatyObject(
                coreType: .CoatyObject,
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
        self.message = message.map { GnosticWirePayload.prefix($0, maximumBytes: 1_200) }
        self.afterSequence = afterSequence
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID, message, afterSequence }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(timelineID, forKey: .timelineID)
        try container.encode(clientTurnID, forKey: .clientTurnID)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encode(afterSequence, forKey: .afterSequence)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        clientTurnID = try GnosticWirePayload.canonicalClientTurnID(
            container.decode(String.self, forKey: .clientTurnID)
        )
        message = try container.decodeIfPresent(String.self, forKey: .message).map { GnosticWirePayload.prefix($0, maximumBytes: 1_200) }
        afterSequence = try container.decodeIfPresent(Int.self, forKey: .afterSequence) ?? 0
    }
}
