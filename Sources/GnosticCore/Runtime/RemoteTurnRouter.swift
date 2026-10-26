// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Routes a Turn for a Timeline this Node does not own to the owner that the
/// network catalog attributes to it.
///
/// The router never admits, journals, or replays the Turn. It forwards the
/// existing provider operations and relays matching update events back under
/// this Node's provider identity so a caller can observe the remote Turn
/// through the router.
@MainActor
final class RemoteTurnRouter {
    private let communication: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let localProviderID: String
    private let timeout: Duration
    private let isRunning: @MainActor () -> Bool
    private var closed = false
    private var turns: [UUID: Task<AscendantTurnResult, Error>] = [:]
    private var cancellations: [UUID: Task<Bool, Never>] = [:]
    private struct Key: Hashable {
        let timelineID: UUID
        let clientTurnID: String
    }
    private final class Relay {
        let observation: Task<RemoteTurnObservation, Error>
        var callers = 0
        var ownerResponded = false
        var owner: String?
        var failure: (any Error)?
        var finishing: Task<Void, Never>?

        init(observation: Task<RemoteTurnObservation, Error>) {
            self.observation = observation
        }
    }
    private var relays: [Key: Relay] = [:]

    init(
        communication: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        isRunning: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(60)
    ) {
        self.communication = communication
        self.catalog = catalog
        self.subscription = subscription
        localProviderID = communication.identity.objectId.string
        self.timeout = timeout
        self.isRunning = isRunning
    }

    func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        guard !closed, isRunning() else { throw NodeRuntimeError.notRunning }
        let id = UUID()
        let task = Task { @MainActor in try await self.performTurn(request) }
        turns[id] = task
        defer { turns[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func shutdown() async {
        closed = true
        let pendingTurns = Array(turns.values)
        let pendingCancellations = Array(cancellations.values)
        let pendingRelays = Array(relays.values)
        pendingTurns.forEach { $0.cancel() }
        pendingCancellations.forEach { $0.cancel() }
        for relay in pendingRelays {
            relay.finishing?.cancel()
            relay.observation.cancel()
            if let observation = try? await relay.observation.value {
                await observation.stopAndWait()
            }
        }
        for task in pendingTurns { _ = await task.result }
        for task in pendingCancellations { _ = await task.result }
    }

    private func performTurn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try Task.checkCancellation()
        guard let clientTurnID = request.clientTurnID else {
            throw AscendantTurnError.terminal(
                timelineID: request.timelineID,
                clientTurnID: "",
                code: "identifiedTurnRequired",
                detail: "A routed Turn requires a clientTurnID so its updates can be observed.",
                retryable: false,
                statusCode: 400
            )
        }
        let key = Key(timelineID: request.timelineID, clientTurnID: clientTurnID)
        let relay: Relay
        if let existing = relays[key] {
            if let finishing = existing.finishing {
                await finishing.value
                return try await turn(request)
            }
            relay = existing
        } else {
            relay = Relay(observation: Task { @MainActor in
                try await RemoteTurnObservation.start(
                    communication: self.communication,
                    timelineID: request.timelineID,
                    clientTurnID: clientTurnID
                )
            })
            relays[key] = relay
        }
        relay.callers += 1
        do {
            let observation = try await relay.observation.value
            let owner = try await resolveOwner(for: request.timelineID)
            try Task.checkCancellation()
            relay.owner = owner
            observation.bind(owner: owner)
            let result = try await callWithOwnerEviction(
                owner: owner,
                timelineID: request.timelineID,
                clientTurnID: request.clientTurnID
            ) {
                try await self.call(
                    owner: owner,
                    operation: AscendantTurnProvider.turnOperation,
                    request: request,
                    context: "ascendant.turn request",
                    returning: AscendantTurnResult.self
                )
            }
            relay.ownerResponded = true
            await finish(relay, key: key)
            return result
        } catch {
            let mapped: any Error = if let failure = error as? RemoteTurnRouteFailure {
                Self.turnFailure(failure, request: request)
            } else { error }
            // A rejected request does not determine the admitted Turn's outcome.
            // In particular a conflicting retry cannot finish its shared relay.
            if (mapped as? AscendantTurnError)?.reasonCode != "turnConflict" {
                relay.failure = mapped
                if let failure = error as? RemoteTurnRouteFailure, case .remote = failure {
                    relay.ownerResponded = true
                }
            }
            await finish(relay, key: key)
            throw mapped
        }
    }

    private func finish(_ relay: Relay, key: Key) async {
        relay.callers -= 1
        guard relay.callers == 0 else { return }
        let finishing = Task { @MainActor in
            if let observation = try? await relay.observation.value {
                if self.closed {
                    await observation.stopAndWait()
                } else if relay.ownerResponded, let owner = relay.owner {
                    do {
                        try await observation.finish { afterSequence in
                            try Task.checkCancellation()
                            return try await self.call(
                                owner: owner,
                                operation: AscendantTurnProvider.replayOperation,
                                request: AscendantTurnReplayRequest(
                                    timelineID: key.timelineID, clientTurnID: key.clientTurnID,
                                    afterSequence: afterSequence
                                ),
                                context: "ascendant.turn.replay request",
                                returning: AscendantTurnReplay.self
                            )
                        }
                    } catch {
                        await observation.finish(error: relay.failure ?? error)
                    }
                } else if let failure = relay.failure {
                    await observation.finish(error: failure)
                } else {
                    observation.stop()
                }
            }
            self.relays[key] = nil
        }
        relay.finishing = finishing
        await finishing.value
    }

    func cancel(timelineID: UUID, clientTurnID: String) async -> Bool {
        guard !closed, isRunning() else { return false }
        let id = UUID()
        let task = Task { @MainActor in
            await self.performCancellation(timelineID: timelineID, clientTurnID: clientTurnID)
        }
        cancellations[id] = task
        defer { cancellations[id] = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func performCancellation(timelineID: UUID, clientTurnID: String) async -> Bool {
        guard !Task.isCancelled, let owner = try? await resolveOwner(for: timelineID) else { return false }
        let request = AscendantTurnCancellationRequest(timelineID: timelineID, clientTurnID: clientTurnID)
        do {
            let result = try await call(
                owner: owner,
                operation: AscendantTurnProvider.cancelOperation,
                request: request,
                context: "ascendant.turn.cancel request",
                returning: AscendantTurnCancellationResult.self
            )
            return result.cancelled
        } catch {
            return false
        }
    }

    private func resolveOwner(for timelineID: UUID) async throws -> String {
        if let owner = await catalog.timelineOwnerID(id: timelineID) {
            return try remoteOwner(owner, for: timelineID)
        }
        await subscription.discover(using: communication, timeout: .seconds(3))
        guard let owner = await catalog.timelineOwnerID(id: timelineID) else {
            throw NodeRuntimeError.missingTimeline(timelineID)
        }
        return try remoteOwner(owner, for: timelineID)
    }

    private func remoteOwner(_ owner: String, for timelineID: UUID) throws -> String {
        guard owner.caseInsensitiveCompare(localProviderID) != .orderedSame else {
            throw NodeRuntimeError.turnFailed(
                "Timeline \(timelineID.uuidString.lowercased()) is local but has no operating Ascendant; refusing to route to self."
            )
        }
        return owner
    }

    private func call<Request: Encodable, Response: Decodable>(
        owner: String,
        operation: String,
        request: Request,
        context: String,
        returning _: Response.Type = Response.self
    ) async throws -> Response {
        let payload = try GnosticWirePayload.encode(request, context: context)
        let response: UnaryCallResult
        do {
            response = try await communication.call(
                operation: operation,
                parameters: String(decoding: payload, as: UTF8.self),
                context: .provider(owner),
                timeout: timeout
            )
        } catch let failure as RemoteCallFailure {
            throw RemoteTurnRouteFailure.remote(failure)
        } catch let error as AxolotyError {
            throw RemoteTurnRouteFailure.transport(error)
        }
        guard response.sourceId?.caseInsensitiveCompare(owner) == .orderedSame else {
            throw RemoteTurnRouteFailure.providerMismatch
        }
        do {
            return try JSONDecoder().decode(Response.self, from: Data(response.result.utf8))
        } catch {
            throw RemoteTurnRouteFailure.invalidResponse
        }
    }

    private func callWithOwnerEviction<Value: Sendable>(
        owner: String,
        timelineID: UUID,
        clientTurnID: String?,
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let evictions = await catalog.providerEvictionStream()
        guard await catalog.timelineOwnerID(id: timelineID)?.caseInsensitiveCompare(owner) == .orderedSame else {
            throw AscendantTurnError.terminal(
                timelineID: timelineID, clientTurnID: clientTurnID ?? "",
                code: "providerOffline", detail: "The Timeline owner left before dispatch.",
                retryable: true, statusCode: 503
            )
        }
        let evicted = RemoteEvictionFlag()
        let call = Task { @MainActor in try await operation() }
        let eviction = Task { @MainActor in
            for await evictedID in evictions
            where evictedID.caseInsensitiveCompare(owner) == .orderedSame {
                evicted.mark()
                call.cancel()
                return
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                call.cancel()
            }
            eviction.cancel()
            await eviction.value
            return result
        } catch {
            eviction.cancel()
            await eviction.value
            if Task.isCancelled { throw CancellationError() }
            if evicted.isMarked {
                throw AscendantTurnError.terminal(
                    timelineID: timelineID,
                    clientTurnID: clientTurnID ?? "",
                    code: "providerOffline",
                    detail: "The Timeline owner left the network before the Turn completed.",
                    retryable: true,
                    statusCode: 503
                )
            }
            throw error
        }
    }

    private static func turnFailure(
        _ failure: RemoteTurnRouteFailure,
        request: AscendantTurnRequest
    ) -> AscendantTurnError {
        let clientTurnID = request.clientTurnID ?? ""
        switch failure {
        case let .remote(remote):
            let decoded = try? JSONDecoder().decode(
                GnosticProtocolFailure.self,
                from: Data(remote.message.utf8)
            )
            return .terminal(
                timelineID: request.timelineID,
                clientTurnID: clientTurnID,
                code: decoded?.reasonCode ?? "callFailed",
                detail: decoded?.message ?? remote.message,
                retryable: decoded?.retryable ?? false,
                statusCode: decoded?.statusCode ?? remote.code
            )
        case let .transport(error):
            if case let .runtime(code, _) = error {
                switch code {
                case .timedOut:
                    return .terminal(
                        timelineID: request.timelineID,
                        clientTurnID: clientTurnID,
                        code: "callTimedOut",
                        detail: "The remote Turn call timed out.",
                        retryable: true,
                        statusCode: 504
                    )
                case .cancelled:
                    return .cancelled(timelineID: request.timelineID, clientTurnID: clientTurnID)
                default:
                    break
                }
            }
            return .terminal(
                timelineID: request.timelineID,
                clientTurnID: clientTurnID,
                code: "transportFailure",
                detail: "The remote Turn transport failed.",
                retryable: true,
                statusCode: 503
            )
        case .providerMismatch:
            return .terminal(
                timelineID: request.timelineID,
                clientTurnID: clientTurnID,
                code: "providerMismatch",
                detail: "The remote owner responded with a different provider identity.",
                retryable: false,
                statusCode: 502
            )
        case .invalidResponse:
            return .terminal(
                timelineID: request.timelineID,
                clientTurnID: clientTurnID,
                code: "invalidResponse",
                detail: "The remote owner returned an invalid result.",
                retryable: false,
                statusCode: 502
            )
        }
    }
}

private enum RemoteTurnRouteFailure: Error {
    case remote(RemoteCallFailure)
    case transport(AxolotyError)
    case providerMismatch
    case invalidResponse
}

@MainActor
private final class RemoteEvictionFlag {
    private(set) var isMarked = false

    func mark() { isMarked = true }
}

/// Relays one remote Turn's update events under the router's provider identity.
@MainActor
private final class RemoteTurnObservation {
    private let communication: CommunicationManager
    private var owner: String?
    private let timelineID: UUID
    private let clientTurnID: String
    private let stream: AsyncStream<ChannelEventSnapshot>
    private var task: Task<Void, Never>?
    private var lastSequence = 0
    private var terminalSeen = false

    static func start(
        communication: CommunicationManager,
        timelineID: UUID,
        clientTurnID: String
    ) async throws -> RemoteTurnObservation {
        let stream = try await communication.observeChannelStream(
            channelId: AscendantTurnProvider.updateChannel
        )
        let observation = RemoteTurnObservation(
            communication: communication,
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            stream: stream
        )
        observation.run()
        return observation
    }

    private init(
        communication: CommunicationManager,
        timelineID: UUID,
        clientTurnID: String,
        stream: AsyncStream<ChannelEventSnapshot>
    ) {
        self.communication = communication
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.stream = stream
    }

    func bind(owner: String) { self.owner = owner }

    func stop() { task?.cancel() }

    func stopAndWait() async {
        task?.cancel()
        await task?.value
    }

    private func run() {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for await snapshot in stream {
                guard let owner, snapshot.sourceId?.caseInsensitiveCompare(owner) == .orderedSame,
                      let raw = snapshot.privateData,
                      let event = try? JSONDecoder().decode(
                          AscendantTurnUpdateStore.Event.self,
                          from: Data(raw.utf8)
                      ),
                      event.timelineID == timelineID,
                      event.clientTurnID == clientTurnID,
                      event.update.sequence > lastSequence else { continue }
                lastSequence = max(lastSequence, event.update.sequence)
                if let channelEvent = try? AscendantTurnProvider.updateEvent(event) {
                    communication.publishChannel(channelEvent)
                }
                if event.update.terminal {
                    terminalSeen = true
                    return
                }
            }
        }
    }

    func finish(
        recover: @MainActor (Int) async throws -> AscendantTurnReplay
    ) async throws {
        await waitForTerminal()
        var cursor = lastSequence
        // Fetch retained pages only to recover the owner's terminal identity.
        // Never invent a success event or replay the prompt.
        while !terminalSeen {
            try Task.checkCancellation()
            let replay = try await recover(cursor)
            if terminalSeen { break }
            if let update = replay.updates.last(where: { $0.terminal }) {
                let event = AscendantTurnUpdateStore.Event(
                    timelineID: timelineID, clientTurnID: clientTurnID, update: update
                )
                communication.publishChannel(try AscendantTurnProvider.updateEvent(event))
                terminalSeen = true
                break
            }
            guard let next = replay.nextSequence, next > cursor else {
                throw AscendantTurnError.replayUnavailable(timelineID: timelineID, clientTurnID: clientTurnID)
            }
            cursor = next
        }
        await stopAndWait()
    }

    func finish(error: Error) async {
        if error is CancellationError {
            task?.cancel()
            return
        }
        await waitForTerminal()
        if !terminalSeen {
            let reason = (error as? AscendantTurnError)?.reasonCode
                ?? (error as? NodeRuntimeError)?.reasonCode
                ?? "remoteTurnFailed"
            let status = (error as? AscendantTurnError)?.statusCode
                ?? (error as? NodeRuntimeError)?.statusCode
                ?? 500
            let retryable = (error as? AscendantTurnError)?.retryable ?? false
            publishTerminal(
                sequence: lastSequence + 1,
                kind: AscendantTurnUpdateKind.error.rawValue,
                text: "The remote Turn failed.",
                reasonCode: reason,
                statusCode: status,
                retryable: retryable
            )
        }
        task?.cancel()
    }

    private func waitForTerminal() async {
        guard owner != nil else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !terminalSeen && !Task.isCancelled && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func publishTerminal(
        sequence: Int,
        kind: String,
        text: String?,
        reasonCode: String?,
        statusCode: Int?,
        retryable: Bool?
    ) {
        let update = AscendantTurnUpdate(
            sequence: sequence,
            kind: kind,
            text: text,
            terminal: true,
            reasonCode: reasonCode,
            statusCode: statusCode,
            retryable: retryable
        )
        let event = AscendantTurnUpdateStore.Event(
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            update: update
        )
        if let channelEvent = try? AscendantTurnProvider.updateEvent(event) {
            communication.publishChannel(channelEvent)
        }
    }
}
