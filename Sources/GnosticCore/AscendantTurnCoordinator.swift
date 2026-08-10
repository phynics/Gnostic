// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Serializes and deduplicates stateful Ascendant Timeline turns for one serve
/// lifetime. A caller may disappear after admission; the coordinator-owned task
/// remains the single owner of the model/tool loop and its terminal outcome.
public actor AscendantTurnCoordinator {
    public typealias TurnOperation = @Sendable () async throws -> String

    private struct Key: Hashable, Sendable {
        let timelineID: UUID
        let clientTurnID: String
    }

    private struct InFlight: Sendable {
        let messageDigest: UInt64
        let task: Task<String, Error>
    }

    private struct Completed: Sendable {
        let messageDigest: UInt64
        let outcome: CachedOutcome
    }

    private enum CachedOutcome: Sendable {
        case succeeded(AgentChatResult)
        case failed(AscendantTurnError)
    }

    private let completedCapacity: Int
    private var inFlight: [Key: InFlight] = [:]
    private var completed: [Key: Completed] = [:]
    private var tombstones: [Key: UInt64] = [:]
    private var completionOrder: [Key] = []
    private var timelineTails: [UUID: Task<Void, Never>] = [:]

    /// - Parameter completedCapacity: Maximum number of terminal outcomes kept
    ///   for replay. The cache is intentionally process-local and bounded.
    public init(completedCapacity: Int = 256) {
        self.completedCapacity = max(1, completedCapacity)
    }

    /// Admits one turn. Requests without a client id use the compatibility path
    /// and are intentionally not deduplicated, while identified requests share
    /// one task per `(timelineID, clientTurnID)` key.
    public func execute(
        _ request: AgentChatRequest,
        operation: @escaping TurnOperation
    ) async throws -> AgentChatResult {
        guard let clientTurnID = request.clientTurnID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientTurnID.isEmpty else {
            let task = enqueue(timelineID: request.timelineID, operation: operation)
            let text = try await task.value
            return AgentChatResult(clientTurnID: UUID().uuidString.lowercased(), text: text)
        }

        let key = Key(timelineID: request.timelineID, clientTurnID: clientTurnID)
        let messageDigest = Self.messageDigest(request.message)
        if let existing = inFlight[key] {
            guard existing.messageDigest == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            return try await replay(existing.task, request: request)
        }

        if let cached = completed[key] {
            guard cached.messageDigest == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            switch cached.outcome {
            case let .succeeded(result):
                return AgentChatResult(clientTurnID: result.clientTurnID, text: result.text, replayed: true)
            case let .failed(error):
                throw error
            }
        }

        if let tombstone = tombstones[key] {
            guard tombstone == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            throw AscendantTurnError.replayUnavailable(
                timelineID: request.timelineID,
                clientTurnID: clientTurnID
            )
        }

        let task = enqueue(timelineID: request.timelineID) {
            do {
                return try await operation()
            } catch is CancellationError {
                throw AscendantTurnError.cancelled(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID
                )
            } catch let error as AscendantTurnError {
                throw error
            } catch {
                throw AscendantTurnError.failed(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID,
                    detail: String(describing: error)
                )
            }
        }

        inFlight[key] = InFlight(messageDigest: messageDigest, task: task)

        // Completion is observed independently of the requesting Call/Return;
        // this makes a lost caller unable to remove the dedupe record early.
        Task { [weak self] in
            let result = await task.result
            await self?.recordCompletion(key: key, request: request, result: result)
        }

        do {
            let text = try await task.value
            recordCompletion(
                key: key,
                request: request,
                result: .success(text)
            )
            return AgentChatResult(clientTurnID: clientTurnID, text: text, replayed: false)
        } catch {
            recordCompletion(
                key: key,
                request: request,
                result: .failure(error)
            )
            throw error
        }
    }

    private func replay(
        _ task: Task<String, Error>,
        request: AgentChatRequest
    ) async throws -> AgentChatResult {
        do {
            let text = try await task.value
            return AgentChatResult(clientTurnID: request.clientTurnID, text: text, replayed: true)
        } catch {
            throw error
        }
    }

    private func recordCompletion(
        key: Key,
        request: AgentChatRequest,
        result: Result<String, Error>
    ) {
        guard inFlight[key] != nil else { return }
        inFlight.removeValue(forKey: key)
        tombstones[key] = Self.messageDigest(request.message)

        let outcome: CachedOutcome
        switch result {
        case let .success(text):
            outcome = .succeeded(AgentChatResult(
                clientTurnID: request.clientTurnID,
                text: text,
                replayed: false
            ))
        case let .failure(error):
            let terminal: AscendantTurnError
            if let error = error as? AscendantTurnError {
                terminal = error
            } else if error is CancellationError {
                terminal = .cancelled(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID ?? ""
                )
            } else {
                terminal = .failed(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID ?? "",
                    detail: String(describing: error)
                )
            }
            outcome = .failed(terminal)
        }

        completed[key] = Completed(messageDigest: Self.messageDigest(request.message), outcome: outcome)
        completionOrder.removeAll { $0 == key }
        completionOrder.append(key)
        while completionOrder.count > completedCapacity {
            let oldest = completionOrder.removeFirst()
            completed.removeValue(forKey: oldest)
        }
    }

    /// A stable, process-local FNV-1a fingerprint keeps the coordinator's
    /// conflict record bounded without retaining the full user message.
    private static func messageDigest(_ message: String) -> UInt64 {
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in message.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return digest
    }

    private func enqueue(
        timelineID: UUID,
        operation: @escaping TurnOperation
    ) -> Task<String, Error> {
        let predecessor = timelineTails[timelineID]
        let task = Task<String, Error> {
            _ = await predecessor?.value
            return try await operation()
        }
        timelineTails[timelineID] = Task { _ = await task.result }
        return task
    }
}
