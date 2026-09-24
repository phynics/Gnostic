// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

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
/// Every call resolves the addressed Timeline from the catalog and requires the
/// Ascendant that owns it to advertise
/// ``GnosticCapability/textTurnInput``. An explicit provider must be the one the
/// catalog attributes to the Timeline. The catalog is consulted first; the
/// client issues an active discover request only when the Timeline is absent.
///
/// A refresh is keyed on the Timeline alone. When the Timeline is already
/// present but its Ascendant projection has not been ingested yet, resolution
/// reports ``GnosticTurnClientError/missingCapability(_:)`` without a second
/// refresh; a caller can retry after the next catalog change.
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
/// There is no `ascendant.turn.cancel` network operation, so this client cannot
/// stop a Turn that a serve has already started. Cancelling the surrounding
/// Swift `Task` stops only the local wait. That missing wire operation is owned
/// as a follow-up by
/// [phynics/Gnostic#294](https://github.com/phynics/Gnostic/issues/294).
@MainActor
public final class GnosticTurnClient {
    private let manager: CommunicationManager
    private let lookup: GnosticCatalogLookup
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
        lookup = GnosticCatalogLookup(manager: manager, catalog: catalog, subscription: subscription, timeout: timeout)
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
    ///   rejected the call.
    public func run(
        message: String,
        timelineID: UUID,
        clientTurnID: String? = nil,
        providerID: String? = nil
    ) async throws -> AscendantTurnResult {
        let target = try await resolvedTurnTarget(providerID, forTimeline: timelineID)
        return try await channel.call(
            AscendantTurnProvider.turnOperation,
            request: AscendantTurnRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID),
            context: "ascendant.turn request",
            providerID: target,
            timeout: promptTimeout,
            returning: AscendantTurnResult.self
        )
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
    ///   rejected the call.
    public func replay(
        timelineID: UUID,
        clientTurnID: String,
        message: String? = nil,
        afterSequence: Int = 0,
        providerID: String? = nil
    ) async throws -> AscendantTurnReplay {
        let target = try await resolvedTurnTarget(providerID, forTimeline: timelineID)
        return try await channel.call(
            AscendantTurnProvider.replayOperation,
            request: AscendantTurnReplayRequest(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                message: message,
                afterSequence: afterSequence
            ),
            context: "ascendant.turn.replay request",
            providerID: target,
            timeout: timeout,
            returning: AscendantTurnReplay.self
        )
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
    ) async throws -> AsyncStream<AscendantTurnUpdate> {
        let expected = try GnosticWirePayload.canonicalClientTurnID(clientTurnID)
        let events = try await updateEvents(providerID: providerID)
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                for await event in events {
                    guard event.timelineID == timelineID,
                          event.clientTurnID == expected else { continue }
                    continuation.yield(event.update)
                    if event.update.terminal {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Answers a pending permission request.
    ///
    /// Read `correlationID`, `timelineID`, and `clientTurnID` from an
    /// ``AscendantTurnUpdate/permissionState`` yielded by ``updates(for:timelineID:providerID:)``.
    /// The decision travels one way over the permission response channel, so
    /// this call reports only that the event was published, not that the serve
    /// accepted it. The result of the decision arrives on the update stream:
    /// the serve records the resolution and resumes or terminates the Turn.
    ///
    /// - Parameters:
    ///   - permission: The correlated permission decision.
    ///   - providerID: The serving provider that must accept the response.
    /// - Throws: A validation error when the response cannot be encoded.
    public func respond(to permission: AscendantPermissionResponse, providerID: String) throws {
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
        let entries = await lookup.entries(requiring: GnosticObjectType.timeline, id: timelineID)
        let providerID: String
        switch GnosticCatalogLookup.provider(
            of: GnosticObjectType.timeline,
            id: timelineID,
            in: entries,
            expected: explicitProviderID
        ) {
        case let .provider(resolved): providerID = resolved
        case .unavailable: throw GnosticTurnClientError.timelineUnavailable(timelineID)
        case .ambiguous: throw GnosticTurnClientError.timelineAmbiguous(timelineID)
        case .mismatch: throw GnosticTurnClientError.providerMismatch
        }
        guard let ascendantID = GnosticCatalogLookup.operatingAscendantID(
            ofTimeline: timelineID,
            providerID: providerID,
            in: entries
        ) else {
            throw GnosticTurnClientError.timelineUnavailable(timelineID)
        }
        guard GnosticCatalogLookup.ascendantAdvertises(
            GnosticCapability.textTurnInput,
            ascendantID: ascendantID,
            providerID: providerID,
            in: entries
        ) else {
            throw GnosticTurnClientError.missingCapability(GnosticCapability.textTurnInput)
        }
        return providerID
    }
}
