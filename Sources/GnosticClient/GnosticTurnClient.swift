// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import GnosticProtocol

/// A public client that runs Turns, streams their updates, replays them by
/// client turn ID, and answers permission requests.
///
/// The client shares the Axoloty transport owned by the
/// ``GnosticConsumerSession`` that created it. It opens no second connection,
/// hosts no Node, and advertises nothing. A caller either addresses the
/// Timeline's provider explicitly after discovery through the session facade,
/// or lets the client resolve it from the session catalog.
///
/// ## Target validation
///
/// Every call resolves the addressed Timeline from the catalog and requires its
/// operating Runtime instance to be advertised by the resolving provider. An
/// advertised Runtime instance provides ``GnosticCapability/textTurnInput``
/// through ACP v2's required `session/prompt` method. An explicit provider
/// must be the one the catalog attributes to the Timeline. The catalog is
/// consulted first; the client issues an active discover request only when the
/// Timeline is absent.
///
/// A refresh is keyed on the Timeline alone. When the Timeline is present but
/// its operating Runtime instance is absent, resolution reports
/// ``GnosticTurnClientError/missingCapability(_:)`` without a second refresh; a
/// caller can retry after the next catalog change.
///
/// ## Lifetime
///
/// The client is valid only while its session is running. After
/// ``GnosticConsumerSession/stop()`` the shared transport is gone and later
/// calls fail by transport timeout; create a new client from a new session
/// instead.
///
/// ## Cancellation
///
/// `cancel(timelineID:clientTurnID:providerID:)` sends an explicit, identified
/// cancellation request. Cancelling the surrounding Swift `Task` alone stops
/// only the local wait; the serve continues to own the admitted Turn.
@MainActor
public final class GnosticTurnClient {
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let resolver: CatalogTargetResolver
    private let channel: GnosticCallChannel<GnosticTurnClientError>
    private let timeout: Duration
    private let promptTimeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration,
        promptTimeout: Duration
    ) {
        self.manager = manager
        self.catalog = catalog
        resolver = CatalogTargetResolver(lookup: GnosticCatalogLookup(
            manager: manager,
            catalog: catalog,
            subscription: subscription,
            timeout: timeout
        ))
        channel = GnosticCallChannel(manager: manager)
        self.timeout = timeout
        self.promptTimeout = promptTimeout
    }

    /// Runs an identified Turn and returns its result.
    ///
    /// - Parameters:
    ///   - message: The text prompt.
    ///   - timelineID: The addressed Timeline.
    ///   - clientTurnID: A stable caller-supplied identifier, or `nil` for a
    ///     non-idempotent request.
    ///   - providerID: The expected provider, or `nil` to resolve the
    ///     Timeline's provider from the session catalog.
    /// - Returns: The Turn result.
    /// - Throws: ``GnosticTurnClientError`` when the target cannot be resolved,
    ///   the addressed provider does not own the Timeline, or the serve
    ///   rejected the call. ``GnosticWirePayload/Error/tooLarge(context:actualBytes:maximumBytes:)``
    ///   when the prompt exceeds ``GnosticWirePayload/maximumTurnMessageBytes``;
    ///   the prompt is rejected before the call, never truncated.
    public func run(
        message: String,
        timelineID: UUID,
        clientTurnID: String? = nil,
        providerID: String? = nil
    ) async throws -> TurnResult {
        let target = try await resolvedTurnTarget(providerID, forTimeline: timelineID)
        return try await callWithProviderEviction(providerID: target) {
            try await self.channel.call(
                AscendantTurnProvider.turnOperation,
                request: TurnRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID),
                context: "turn request",
                providerID: target,
                timeout: self.promptTimeout,
                returning: TurnResult.self
            )
        }
    }

    /// Runs an identified Turn through a router Node.
    ///
    /// The router Node is expected to forward the request to the Timeline
    /// owner and relay the owner's updates under its own provider identity.
    /// Use ``updates(for:timelineID:providerID:)`` with `routerID` to observe
    /// the relayed updates. Unlike ``run(message:timelineID:clientTurnID:providerID:)``,
    /// this method does not require the addressed provider to own the
    /// Timeline.
    ///
    /// - Parameters:
    ///   - message: The text prompt.
    ///   - timelineID: The addressed Timeline.
    ///   - clientTurnID: A stable caller-supplied identifier, required to
    ///     correlate the owner's relayed updates.
    ///   - routerID: The provider that routes the Turn to the owner.
    /// - Returns: The Turn result reported by the owner.
    /// - Throws: ``GnosticTurnClientError`` when the router rejects the call
    ///   or the call fails. ``GnosticWirePayload/Error/tooLarge(context:actualBytes:maximumBytes:)``
    ///   when the prompt exceeds ``GnosticWirePayload/maximumTurnMessageBytes``.
    public func runRouted(
        message: String,
        timelineID: UUID,
        clientTurnID: String,
        routerID: String
    ) async throws -> TurnResult {
        try Self.requireRouterID(routerID)
        return try await callWithProviderEviction(providerID: routerID) {
            try await self.channel.call(
                AscendantTurnProvider.turnOperation,
                request: TurnRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID),
                context: "turn request",
                providerID: routerID,
                timeout: self.promptTimeout,
                returning: TurnResult.self
            )
        }
    }

    /// Requests cancellation of one admitted identified Turn through a router
    /// Node.
    ///
    /// The router is expected to forward the cancellation to the Timeline
    /// owner. A `true` result means the owner accepted cancellation for the
    /// matching in-flight Turn.
    public func cancelRouted(
        timelineID: UUID,
        clientTurnID: String,
        routerID: String
    ) async throws -> Bool {
        try Self.requireRouterID(routerID)
        return try await callWithProviderEviction(providerID: routerID) {
            try await self.channel.call(
                AscendantTurnProvider.cancelOperation,
                request: TurnCancellationRequest(timelineID: timelineID, clientTurnID: clientTurnID),
                context: "turn.cancel request",
                providerID: routerID,
                timeout: self.timeout,
                returning: TurnCancellationResult.self
            ).cancelled
        }
    }

    private static func requireRouterID(_ routerID: String) throws {
        guard !routerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GnosticTurnClientError.callFailed(
                reasonCode: "invalidRouterID",
                statusCode: 400,
                retryable: false
            )
        }
    }

    /// Requests cancellation of one admitted identified Turn.
    ///
    /// The request is scoped by both Timeline and client Turn identity. A
    /// `true` result means the serving coordinator accepted cancellation for
    /// the matching in-flight Turn; it does not guarantee that the backend or
    /// external agent will stop if it ignores cancellation.
    public func cancel(
        timelineID: UUID,
        clientTurnID: String,
        providerID: String? = nil
    ) async throws -> Bool {
        let target = try await resolvedTurnTarget(providerID, forTimeline: timelineID)
        return try await callWithProviderEviction(providerID: target) {
            try await self.channel.call(
                AscendantTurnProvider.cancelOperation,
                request: TurnCancellationRequest(timelineID: timelineID, clientTurnID: clientTurnID),
                context: "turn.cancel request",
                providerID: target,
                timeout: self.timeout,
                returning: TurnCancellationResult.self
            ).cancelled
        }
    }

    /// Reads the retained updates for an identified Turn.
    ///
    /// This call applies the same target resolution and `textTurnInput`
    /// capability gate as ``run(message:timelineID:clientTurnID:providerID:)``.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the Turn ran on.
    ///   - clientTurnID: The identifier the Turn was run with.
    ///   - message: The original prompt, when the caller wants a content
    ///     conflict to be reported instead of replayed.
    ///   - afterSequence: The last sequence the caller already observed.
    ///   - providerID: The expected provider, or `nil` to resolve the
    ///     Timeline's provider from the session catalog.
    /// - Returns: The bounded replay, including the updates the serve retained.
    /// - Throws: ``GnosticTurnClientError`` when the target cannot be resolved,
    ///   the addressed provider does not own the Timeline, or the serve
    ///   rejected the call. ``GnosticWirePayload/Error/tooLarge(context:actualBytes:maximumBytes:)``
    ///   when a supplied `message` exceeds
    ///   ``GnosticWirePayload/maximumTurnMessageBytes``; the message is
    ///   rejected before the call, never truncated.
    public func replay(
        timelineID: UUID,
        clientTurnID: String,
        message: String? = nil,
        afterSequence: Int = 0,
        providerID: String? = nil
    ) async throws -> TurnReplay {
        let target = try await resolvedTurnTarget(providerID, forTimeline: timelineID)
        return try await callWithProviderEviction(providerID: target) {
            try await self.channel.call(
                AscendantTurnProvider.replayOperation,
                request: TurnReplayRequest(
                    timelineID: timelineID,
                    clientTurnID: clientTurnID,
                    message: message,
                    afterSequence: afterSequence
                ),
                context: "turn.replay request",
                providerID: target,
                timeout: self.timeout,
                returning: TurnReplay.self
            )
        }
    }

    /// Streams the live updates for one identified Turn.
    ///
    /// Subscribe before running the Turn so no update is missed. The stream is
    /// bounded and finishes after it yields the Turn's terminal update, so a
    /// `for await` loop exits at completion instead of waiting for transport
    /// teardown.
    ///
    /// The bounded buffer is latest-biased: under backpressure it drops the
    /// oldest pending update. A caller that must observe every update reliably
    /// should recover from ``replay(timelineID:clientTurnID:message:afterSequence:providerID:)``
    /// instead of trusting the live stream to be lossless.
    ///
    /// - Parameters:
    ///   - clientTurnID: The identifier used to run the Turn.
    ///   - timelineID: The Timeline the Turn runs on.
    ///   - providerID: The provider to filter on, or `nil` for every provider.
    /// - Returns: A bounded stream of Turn updates that finishes on the
    ///   terminal update.
    /// - Throws: ``GnosticWirePayload`` validation errors for an invalid
    ///   `clientTurnID`.
    public func updates(
        for clientTurnID: String,
        timelineID: UUID,
        providerID: String? = nil
    ) async throws -> AsyncStream<TurnUpdate> {
        let expected = try GnosticWirePayload.canonicalClientTurnID(clientTurnID)
        let events = try await updateEvents(providerID: providerID)
        let watchedProvider: String?
        if let providerID {
            watchedProvider = providerID
        } else {
            watchedProvider = await catalog.timelineOwnerID(id: timelineID)
        }
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let sequence = TurnUpdateSequence()
            let eventTask = Task { @MainActor in
                for await event in events {
                    guard event.timelineID == timelineID,
                          event.clientTurnID == expected else { continue }
                    sequence.advance(to: event.update.sequence)
                    continuation.yield(event.update)
                    if event.update.terminal {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            let evictionTask = Task { @MainActor [catalog] in
                guard let watchedProvider else { return }
                let evictions = await catalog.providerEvictionStream()
                for await evicted in evictions
                where evicted.caseInsensitiveCompare(watchedProvider) == .orderedSame {
                    continuation.yield(TurnUpdate(
                        sequence: sequence.next,
                        kind: TurnUpdateKind.error.rawValue,
                        text: "The Timeline owner left the network before the Turn completed.",
                        terminal: true,
                        reasonCode: "providerOffline",
                        statusCode: 503,
                        retryable: true
                    ))
                    continuation.finish()
                    return
                }
            }
            continuation.onTermination = { _ in
                eventTask.cancel()
                evictionTask.cancel()
            }
        }
    }

    /// Runs one provider-addressed call and fails as soon as the catalog
    /// evicts that provider, instead of waiting for the call timeout.
    private func callWithProviderEviction<Value: Sendable>(
        providerID: String,
        _ operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let evicted = ProviderEvictionFlag()
        let call = Task { @MainActor in try await operation() }
        let eviction = Task { @MainActor [catalog] in
            let evictions = await catalog.providerEvictionStream()
            for await evictedID in evictions
            where evictedID.caseInsensitiveCompare(providerID) == .orderedSame {
                evicted.mark()
                call.cancel()
                return
            }
        }
        defer { eviction.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                call.cancel()
            }
        } catch {
            if evicted.isMarked {
                throw GnosticTurnClientError.callFailed(
                    reasonCode: "providerOffline",
                    statusCode: 503,
                    retryable: true
                )
            }
            throw error
        }
    }

    /// Answers a pending permission request.
    ///
    /// Read `correlationID`, `timelineID`, and `clientTurnID` from an
    /// ``TurnUpdate/permissionState`` yielded by ``updates(for:timelineID:providerID:)``.
    /// The decision travels one way over the permission response channel, so
    /// this call reports only that the event was published, not that the serve
    /// accepted it. The result of the decision arrives on the update stream:
    /// the serve records the resolution and resumes or terminates the Turn.
    ///
    /// - Parameters:
    ///   - permission: The correlated permission decision.
    ///   - providerID: The serving provider that must accept the response.
    /// - Throws: A validation error when the response cannot be encoded.
    public func respond(to permission: TurnPermissionResponse, providerID: String) throws {
        manager.publishChannel(try AscendantPermissionProvider.responseEvent(permission.targeted(to: providerID)))
    }

    private func updateEvents(providerID: String?) async throws -> AsyncStream<AscendantTurnUpdateStore.Event> {
        let snapshots = try await manager.observeChannelStream(channelId: AscendantTurnProvider.updateChannel)
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                for await snapshot in snapshots {
                    if let providerID,
                       snapshot.sourceId?.lowercased() != providerID.lowercased() { continue }
                    guard let raw = snapshot.privateData,
                          let event = try? JSONDecoder().decode(
                              AscendantTurnUpdateStore.Event.self,
                              from: Data(raw.utf8)
                          ) else { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolvedTurnTarget(_ explicitProviderID: String?, forTimeline timelineID: UUID) async throws -> String {
        switch await resolver.resolve(
            .timeline,
            id: timelineID,
            expectedProviderID: explicitProviderID,
            requiredCapability: GnosticCapability.textTurnInput
        ) {
        case let .success(target): return target.providerID
        case let .failure(failure): throw Self.error(for: failure, timeline: timelineID)
        }
    }

    /// The one mapping from catalog target failures to Turn client errors.
    static func error(for failure: CatalogTargetFailure, timeline timelineID: UUID) -> GnosticTurnClientError {
        switch failure {
        case .unavailable: .timelineUnavailable(timelineID)
        case .ambiguous: .timelineAmbiguous(timelineID)
        case .providerMismatch: .providerMismatch
        case let .missingCapability(capability): .missingCapability(capability)
        }
    }
}

@MainActor
private final class ProviderEvictionFlag {
    private(set) var isMarked = false

    func mark() { isMarked = true }
}

@MainActor
private final class TurnUpdateSequence {
    private var last = 0

    func advance(to sequence: Int) { last = max(last, sequence) }
    var next: Int { last + 1 }
}
