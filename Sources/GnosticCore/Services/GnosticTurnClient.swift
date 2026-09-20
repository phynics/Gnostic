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
    /// Subscribe before running the Turn so no update is missed. The stream is
    /// bounded and finishes after it yields the Turn's terminal update, so a
    /// `for await` loop exits at completion instead of waiting for transport
    /// teardown.
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
        var entries = await catalog.networkObjects()
        if !entries.contains(where: { $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID }) {
            await subscription.discover(using: manager, timeout: timeout)
            entries = await catalog.networkObjects()
        }
        let timelines = entries.filter {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
        }
        let providers = Set(timelines.map { $0.providerID.lowercased() })
        guard let providerID = timelines.first?.providerID else {
            throw GnosticTurnClientError.timelineUnavailable(timelineID)
        }
        guard providers.count == 1 else {
            throw GnosticTurnClientError.timelineAmbiguous(timelineID)
        }
        if let explicitProviderID, explicitProviderID.caseInsensitiveCompare(providerID) != .orderedSame {
            throw GnosticTurnClientError.providerMismatch
        }
        let attachedAscendantIDs = Set(timelines.compactMap { entry -> UUID? in
            guard case let .string(raw) = entry.knownProperties["attachedAscendantID"] else { return nil }
            return UUID(uuidString: raw)
        })
        guard attachedAscendantIDs.count == 1, let ascendantID = attachedAscendantIDs.first else {
            throw GnosticTurnClientError.timelineUnavailable(timelineID)
        }
        guard entries.contains(where: { entry in
            entry.objectType == GnosticObjectType.ascendant
                && entry.objectID == ascendantID
                && entry.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && Self.capabilities(of: entry).contains(GnosticCapability.textTurnInput)
        }) else {
            throw GnosticTurnClientError.missingCapability(GnosticCapability.textTurnInput)
        }
        return providerID
    }

    private func call(
        operation: String,
        parameters: String,
        providerID: String,
        timeout: Duration
    ) async throws -> UnaryCallResult {
        let response: UnaryCallResult
        do {
            response = try await manager.call(
                operation: operation,
                parameters: parameters,
                context: Self.providerContext(providerID),
                timeout: timeout
            )
        } catch let failure as RemoteCallFailure {
            let decoded = try? JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(failure.message.utf8))
            throw GnosticTurnClientError.callFailed(
                reasonCode: decoded?.reasonCode ?? "callFailed",
                statusCode: decoded?.statusCode ?? failure.code,
                retryable: decoded?.retryable ?? false
            )
        }
        guard response.sourceId?.lowercased() == providerID.lowercased() else {
            throw GnosticTurnClientError.providerMismatch
        }
        return response
    }

    private static func capabilities(of entry: NetworkCatalogEntry) -> [String] {
        guard case let .array(values) = entry.knownProperties["capabilities"] else { return [] }
        return values.compactMap { value in
            guard case let .string(capability) = value else { return nil }
            return capability
        }
    }

    private static func providerContext(_ providerID: String) -> ObjectFilter {
        ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        ))
    }
}
