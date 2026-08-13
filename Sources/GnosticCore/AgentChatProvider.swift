// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// The wire payload for a remote `agent.chat` turn.
public struct AgentChatRequest: Codable, Sendable {
    public let message: String
    public let timelineID: UUID
    public let clientTurnID: String?

    public init(message: String, timelineID: UUID, clientTurnID: String? = nil) {
        self.message = message
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
    }
}

/// The wire result of a remote `agent.chat` turn.
public struct AgentChatResult: Codable, Sendable {
    public let clientTurnID: String?
    public let text: String
    public let replayed: Bool

    public init(clientTurnID: String? = nil, text: String, replayed: Bool = false) {
        self.clientTurnID = clientTurnID
        self.text = text
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case clientTurnID
        case text
        case replayed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientTurnID = try container.decodeIfPresent(String.self, forKey: .clientTurnID)
        text = try container.decode(String.self, forKey: .text)
        // Older serves returned only `{text}`. Keep that response readable while
        // new callers receive the explicit replay marker.
        replayed = try container.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
    }
}

/// Terminal failures retained by the serve-lifetime turn coordinator.
public enum AscendantTurnError: Error, Sendable, Equatable, LocalizedError {
    case conflict(timelineID: UUID, clientTurnID: String)
    case failed(timelineID: UUID, clientTurnID: String, detail: String)
    case cancelled(timelineID: UUID, clientTurnID: String)
    case replayUnavailable(timelineID: UUID, clientTurnID: String)

    public var errorDescription: String? {
        switch self {
        case let .conflict(timelineID, clientTurnID):
            "clientTurnID \(clientTurnID) was already used with different content on Timeline \(timelineID.uuidString.lowercased())"
        case let .failed(_, _, detail):
            detail
        case let .cancelled(_, clientTurnID):
            "agent.chat turn \(clientTurnID) was cancelled"
        case let .replayUnavailable(_, clientTurnID):
            "the replay result for agent.chat turn \(clientTurnID) is no longer retained; the turn will not be rerun"
        }
    }

    public var statusCode: Int {
        switch self {
        case .conflict: 409
        case .failed: 500
        case .cancelled: 499
        case .replayUnavailable: 410
        }
    }
}

/// Hosts the `me.atkn.gnostic.agent.chat` unary Call/Return operation.
///
/// A thin wire adapter: decodes an `AgentChatRequest`, invokes the injected
/// turn closure (owned by the serve runtime), and encodes the result —
/// mirroring `WorkspaceProvider`'s contract.
public struct AgentChatProvider: Sendable {
    public static let chatOperation = "me.atkn.gnostic.agent.chat"
    public static let replayOperation = "me.atkn.gnostic.agent.chat.replay"
    public static let updateChannel = "me.atkn.gnostic.agent.chat.update"

    public typealias TurnExecutor = @Sendable (AgentChatRequest) async throws -> AgentChatResult

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
            return .failure(code: 503, message: "notRunning: The node runtime is not running.")
        }
        guard let parameters,
              let request = try? JSONDecoder().decode(AgentChatRequest.self, from: Data(parameters.utf8)) else {
            return .failure(code: 400, message: "Invalid agent.chat payload")
        }
        if let clientTurnID = request.clientTurnID,
           clientTurnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(code: 400, message: "clientTurnID must not be empty")
        }
        do {
            if let replayStore, let clientTurnID = request.clientTurnID {
                await replayStore.start(timelineID: request.timelineID, clientTurnID: clientTurnID, message: request.message)
            }
            let result = try await executor(request)
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
            let encoded = try JSONEncoder().encode(result)
            return .success(result: String(decoding: encoded, as: UTF8.self))
        } catch let error as AscendantTurnError {
            if let replayStore, let clientTurnID = request.clientTurnID,
               !isAdmissionOnlyError(error) {
                _ = await replayStore.append(timelineID: request.timelineID, clientTurnID: clientTurnID, kind: "error", text: error.localizedDescription, terminal: true)
            }
            return .failure(code: error.statusCode, message: error.localizedDescription)
        } catch let error as NodeRuntimeError {
            if let replayStore, let clientTurnID = request.clientTurnID {
                _ = await replayStore.append(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID,
                    kind: "error",
                    text: error.localizedDescription,
                    terminal: true
                )
            }
            return .failure(code: error.statusCode, message: error.reasonCode + ": " + error.localizedDescription)
        } catch {
            if let replayStore, let clientTurnID = request.clientTurnID {
                _ = await replayStore.append(timelineID: request.timelineID, clientTurnID: clientTurnID, kind: "error", text: String(describing: error), terminal: true)
            }
            return .failure(code: 500, message: String(describing: error))
        }
    }

    private func isAdmissionOnlyError(_ error: AscendantTurnError) -> Bool {
        switch error {
        case .conflict, .replayUnavailable: return true
        case .failed, .cancelled: return false
        }
    }

    public func handleReplay(parameters: String?) async throws -> CallHandlerResult {
        guard await isAvailable() else {
            return .failure(code: 503, message: "notRunning: The node runtime is not running.")
        }
        guard let replayStore,
              let parameters,
              let request = try? JSONDecoder().decode(AgentChatReplayRequest.self, from: Data(parameters.utf8)),
              !request.clientTurnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(code: 400, message: "Invalid agent.chat.replay payload")
        }
        let replay = await replayStore.replay(
            timelineID: request.timelineID,
            clientTurnID: request.clientTurnID,
            message: request.message,
            afterSequence: request.afterSequence
        )
        if replay.conflict {
            return .failure(code: 409, message: "clientTurnID was already used with different content")
        }
        let encoded = try JSONEncoder().encode(replay)
        return .success(result: String(decoding: encoded, as: UTF8.self))
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.chatOperation, context: context) { [self] request in
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
        let data = try JSONEncoder().encode(event)
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

public struct AgentChatReplayRequest: Codable, Sendable {
    public let timelineID: UUID
    public let clientTurnID: String
    public let message: String?
    public let afterSequence: Int

    public init(timelineID: UUID, clientTurnID: String, message: String? = nil, afterSequence: Int = 0) {
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.message = message
        self.afterSequence = afterSequence
    }
}
