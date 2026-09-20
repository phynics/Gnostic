// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// A public client that runs Turns, streams their updates, replays them by
/// client turn ID, and answers permission requests.
///
/// The client shares the Axoloty transport owned by the
/// ``GnosticConsumerSession`` that created it. It opens no second connection,
/// hosts no Node, and advertises nothing. A caller either addresses a provider
/// explicitly after discovery through the session facade, or lets the client
/// resolve the provider that advertises the addressed Timeline.
///
/// ## Cancellation
///
/// The current wire contract has no remote Turn-cancellation operation, so this
/// client cannot stop a Turn that a serve has already started. Cancelling the
/// surrounding Swift `Task` stops only the local wait. Remote cancellation is
/// tracked separately by
/// [phynics/Gnostic#294](https://github.com/phynics/Gnostic/issues/294).
@MainActor
public final class GnosticTurnClient {
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
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
        self.subscription = subscription
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
    ///   - providerID: The provider to address, or `nil` to resolve the
    ///     Timeline's live provider from the session catalog.
    /// - Returns: The Turn result.
    /// - Throws: ``GnosticTurnClientError`` when the target cannot be resolved
    ///   or the response came from another provider.
    public func run(
        message: String,
        timelineID: UUID,
        clientTurnID: String? = nil,
        providerID: String? = nil
    ) async throws -> AscendantTurnResult {
        let target = try await resolvedProviderID(providerID, forTimeline: timelineID)
        let payload = try GnosticWirePayload.encode(
            AscendantTurnRequest(message: message, timelineID: timelineID, clientTurnID: clientTurnID),
            context: "ascendant.turn request"
        )
        let response = try await call(
            operation: AscendantTurnProvider.turnOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: target,
            timeout: promptTimeout
        )
        return try JSONDecoder().decode(AscendantTurnResult.self, from: Data(response.result.utf8))
    }

    /// Reads the retained updates for an identified Turn.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the Turn ran on.
    ///   - clientTurnID: The identifier the Turn was run with.
    ///   - message: The original prompt, when the caller wants a content
    ///     conflict to be reported instead of replayed.
    ///   - afterSequence: The last sequence the caller already observed.
    ///   - providerID: The provider to address, or `nil` to resolve the
    ///     Timeline's live provider from the session catalog.
    /// - Returns: The bounded replay, including the updates the serve retained.
    /// - Throws: ``GnosticTurnClientError`` when the target cannot be resolved
    ///   or the response came from another provider.
    public func replay(
        timelineID: UUID,
        clientTurnID: String,
        message: String? = nil,
        afterSequence: Int = 0,
        providerID: String? = nil
    ) async throws -> AscendantTurnReplay {
        let target = try await resolvedProviderID(providerID, forTimeline: timelineID)
        let payload = try GnosticWirePayload.encode(
            AscendantTurnReplayRequest(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                message: message,
                afterSequence: afterSequence
            ),
            context: "ascendant.turn.replay request"
        )
        let response = try await call(
            operation: AscendantTurnProvider.replayOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: target,
            timeout: timeout
        )
        return try JSONDecoder().decode(AscendantTurnReplay.self, from: Data(response.result.utf8))
    }

    /// Streams the live updates for one identified Turn.
    ///
    /// Subscribe before running the Turn so no update is missed. The stream
    /// finishes when the underlying channel closes; a consumer typically stops
    /// at the first terminal update.
    ///
    /// - Parameters:
    ///   - clientTurnID: The identifier used to run the Turn.
    ///   - timelineID: The Timeline the Turn runs on.
    ///   - providerID: The provider to filter on, or `nil` for every provider.
    /// - Returns: A bounded stream of Turn updates.
    /// - Throws: ``GnosticWirePayload`` validation errors for an invalid
    ///   `clientTurnID`.
    public func updates(
        for clientTurnID: String,
        timelineID: UUID,
        providerID: String? = nil
    ) async throws -> AsyncStream<AscendantTurnUpdate> {
        let expected = try GnosticWirePayload.canonicalClientTurnID(clientTurnID)
        let events = try await updateEvents(providerID: providerID)
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    guard event.timelineID == timelineID,
                          event.clientTurnID == expected else { continue }
                    continuation.yield(event.update)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Answers a pending permission request.
    ///
    /// - Parameters:
    ///   - permission: The correlated permission decision.
    ///   - providerID: The serving provider to target, or `nil` to broadcast.
    /// - Throws: A validation error when the response cannot be encoded.
    public func respond(to permission: AscendantPermissionResponse, providerID: String? = nil) async throws {
        manager.publishChannel(try AscendantPermissionProvider.responseEvent(permission.targeted(to: providerID)))
    }

    private func updateEvents(providerID: String?) async throws -> AsyncStream<AscendantTurnUpdateStore.Event> {
        let snapshots = try await manager.observeChannelStream(channelId: AscendantTurnProvider.updateChannel)
        return AsyncStream { continuation in
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

    private func resolvedProviderID(_ explicit: String?, forTimeline timelineID: UUID) async throws -> String {
        if let explicit { return explicit }
        await subscription.discover(using: manager, timeout: timeout)
        let entries = await catalog.networkObjects()
        let providers = Set(entries.filter {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
        }.map(\.providerID))
        guard let providerID = providers.first else {
            throw GnosticTurnClientError.timelineUnavailable(timelineID)
        }
        guard providers.count == 1 else {
            throw GnosticTurnClientError.timelineAmbiguous(timelineID)
        }
        return providerID
    }

    private func call(
        operation: String,
        parameters: String,
        providerID: String,
        timeout: Duration
    ) async throws -> UnaryCallResult {
        let response = try await manager.call(
            operation: operation,
            parameters: parameters,
            context: Self.providerContext(providerID),
            timeout: timeout
        )
        guard response.sourceId?.lowercased() == providerID.lowercased() else {
            throw GnosticTurnClientError.providerMismatch
        }
        return response
    }

    private static func providerContext(_ providerID: String) -> ObjectFilter {
        ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        ))
    }
}
