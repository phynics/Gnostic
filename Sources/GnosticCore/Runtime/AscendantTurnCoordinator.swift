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

    private struct Lane: Sendable {
        let id: UUID
        let task: Task<String, Error>
        let tail: Task<Void, Never>
    }

    private enum CachedOutcome: Sendable {
        case succeeded(AscendantTurnResult)
        case failed(AscendantTurnError)
    }

    private let completedCapacity: Int
    private var inFlight: [Key: InFlight] = [:]
    private var completed: [Key: Completed] = [:]
    private var tombstones: [Key: UInt64] = [:]
    private var completionOrder: [Key] = []
    private var tombstoneOrder: [Key] = []
    private var timelineTails: [UUID: Lane] = [:]

    internal var retainedStateCounts: (completed: Int, tombstones: Int) {
        (completed.count, tombstones.count)
    }

    internal var retainedTimelineCount: Int { timelineTails.count }

    internal var inFlightCount: Int { inFlight.count }

    /// - Parameter completedCapacity: Maximum number of terminal outcomes kept
    ///   for replay. The cache is intentionally process-local and bounded.
    public init(completedCapacity: Int = 256) {
        self.completedCapacity = max(1, completedCapacity)
    }

    /// Cancels admitted work during node shutdown. New requests are rejected by
    /// the owning NodeRuntime before reaching this coordinator.
    public func cancelAll(waitForCompletion: Bool = true) async {
        let turns = inFlight.values.map(\.task) + timelineTails.values.map(\.task)
        let tails = timelineTails.values.map(\.tail)
        turns.forEach { $0.cancel() }
        tails.forEach { $0.cancel() }
        guard waitForCompletion else { return }
        for turn in turns { _ = await turn.result }
        for tail in tails { await tail.value }
    }

    /// Admits one turn. Requests without a client id use the compatibility path
    /// and are intentionally not deduplicated, while identified requests share
    /// one task per `(timelineID, clientTurnID)` key.
    public func execute(
        _ request: AscendantTurnRequest,
        operation: @escaping TurnOperation
    ) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        guard let rawClientTurnID = request.clientTurnID else {
            let lane = enqueue(timelineID: request.timelineID, operation: operation)
            do {
                let text = try await lane.task.value
                removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
                return AscendantTurnResult(clientTurnID: UUID().uuidString.lowercased(), text: text)
            } catch {
                removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
                throw error
            }
        }
        let clientTurnID = try GnosticWirePayload.canonicalClientTurnID(rawClientTurnID)
        let canonicalRequest = AscendantTurnRequest(
            message: request.message,
            timelineID: request.timelineID,
            clientTurnID: clientTurnID,
            protocolMajor: request.protocolMajor
        )

        let key = Key(timelineID: request.timelineID, clientTurnID: clientTurnID)
        let messageDigest = Self.messageDigest(request.message)
        if let existing = inFlight[key] {
            guard existing.messageDigest == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            return try await replay(existing.task, request: canonicalRequest)
        }

        if let cached = completed[key] {
            guard cached.messageDigest == messageDigest else {
                throw AscendantTurnError.conflict(timelineID: request.timelineID, clientTurnID: clientTurnID)
            }
            switch cached.outcome {
            case let .succeeded(result):
                return AscendantTurnResult(clientTurnID: result.clientTurnID, text: result.text, replayed: true)
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

        let lane = enqueue(timelineID: request.timelineID) {
            do {
                return try await operation()
            } catch is CancellationError {
                throw AscendantTurnError.cancelled(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID
                )
            } catch let error as AscendantBackendError {
                if case .cancelled = error {
                    throw AscendantTurnError.cancelled(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID
                    )
                }
                if case let .lifecycleUnusable(failure) = error {
                    throw AscendantTurnError.lifecycleUnusable(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID,
                        detail: failure.message
                    )
                }
                if case let .terminal(failure) = error {
                    throw AscendantTurnError.terminal(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID,
                        code: failure.code,
                        detail: failure.message,
                        retryable: failure.retryable
                    )
                }
                throw AscendantTurnError.terminal(
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID,
                    code: error.reasonCode,
                    detail: error.localizedDescription,
                    retryable: false
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

        let task = lane.task
        inFlight[key] = InFlight(messageDigest: messageDigest, task: task)

        // Completion is observed independently of the requesting Call/Return;
        // this makes a lost caller unable to remove the dedupe record early.
        Task { [weak self] in
            let result = await task.result
            await self?.recordCompletion(key: key, request: canonicalRequest, result: result)
        }

        do {
            let text = try await task.value
            removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
            recordCompletion(
                key: key,
                request: canonicalRequest,
                result: .success(text)
            )
            return AscendantTurnResult(clientTurnID: clientTurnID, text: text, replayed: false)
        } catch {
            removeTimelineTail(timelineID: request.timelineID, laneID: lane.id)
            recordCompletion(
                key: key,
                request: canonicalRequest,
                result: .failure(error)
            )
            throw error
        }
    }

    private func replay(
        _ task: Task<String, Error>,
        request: AscendantTurnRequest
    ) async throws -> AscendantTurnResult {
        do {
            let text = try await task.value
            return AscendantTurnResult(clientTurnID: request.clientTurnID, text: text, replayed: true)
        } catch {
            throw error
        }
    }

    private func recordCompletion(
        key: Key,
        request: AscendantTurnRequest,
        result: Result<String, Error>
    ) {
        guard inFlight[key] != nil else { return }
        inFlight.removeValue(forKey: key)
        let digest = Self.messageDigest(request.message)
        if tombstones[key] == nil, tombstones.count < completedCapacity {
            tombstones[key] = digest
            tombstoneOrder.append(key)
        } else if tombstones[key] != nil {
            tombstones[key] = digest
        }

        let outcome: CachedOutcome
        switch result {
        case let .success(text):
            outcome = .succeeded(AscendantTurnResult(
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
    ) -> Lane {
        let predecessor = timelineTails[timelineID]?.tail
        let task = Task<String, Error> {
            _ = await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        let laneID = UUID()
        let tail = Task { [weak self] in
            _ = await task.result
            await self?.removeTimelineTail(timelineID: timelineID, laneID: laneID)
        }
        let lane = Lane(id: laneID, task: task, tail: tail)
        timelineTails[timelineID] = lane
        return lane
    }

    private func removeTimelineTail(timelineID: UUID, laneID: UUID) {
        guard timelineTails[timelineID]?.id == laneID else { return }
        timelineTails.removeValue(forKey: timelineID)
    }
}
