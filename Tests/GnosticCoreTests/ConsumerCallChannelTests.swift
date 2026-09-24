// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
@testable import GnosticCore
import Testing

/// Broker-free checks of the call and catalog seam every public consumer
/// client shares. The broker-backed facade suites cover the same behavior end
/// to end.
@Suite("Consumer call channel")
@MainActor
struct ConsumerCallChannelTests {
    private typealias TurnChannel = GnosticCallChannel<GnosticTurnClientError>
    private typealias WorkspaceChannel = GnosticCallChannel<GnosticWorkspaceClientError>
    private typealias TimelineChannel = GnosticCallChannel<GnosticTimelineClientError>

    @Test("transport failures normalize to one reason, status, and retry policy for every client")
    func transportFailures() {
        let timedOut = AxolotyError.runtime(code: .timedOut, reason: "deadline")
        let cancelled = AxolotyError.runtime(code: .cancelled, reason: "cancelled")
        let unavailable = AxolotyError.runtime(code: .brokerUnavailable, reason: "offline")

        #expect(TurnChannel.transportFailure(timedOut) == .callFailed(reasonCode: "callTimedOut", statusCode: 504, retryable: true))
        #expect(TurnChannel.transportFailure(cancelled) == .callFailed(reasonCode: "callCancelled", statusCode: 499, retryable: false))
        #expect(TurnChannel.transportFailure(unavailable) == .callFailed(reasonCode: "transportFailure", statusCode: 503, retryable: true))
        #expect(WorkspaceChannel.transportFailure(timedOut) == .callFailed(reasonCode: "callTimedOut", statusCode: 504, retryable: true))
        #expect(TimelineChannel.transportFailure(cancelled) == .callFailed(reasonCode: "callCancelled", statusCode: 499, retryable: false))
    }

    @Test("a serve protocol failure keeps its reason, status, and retryability")
    func protocolFailureBody() throws {
        let body = try JSONEncoder().encode(GnosticProtocolFailure(
            reasonCode: "turnConflict",
            message: "conflict",
            statusCode: 409,
            retryable: true
        ))
        let failure = RemoteCallFailure(code: 500, message: String(decoding: body, as: UTF8.self))

        #expect(TurnChannel.remoteFailure(failure) == .callFailed(reasonCode: "turnConflict", statusCode: 409, retryable: true))
        #expect(WorkspaceChannel.remoteFailure(failure) == .callFailed(reasonCode: "turnConflict", statusCode: 409, retryable: true))
    }

    @Test("a remote failure without a protocol body keeps its transport status")
    func bareRemoteFailure() {
        let failure = RemoteCallFailure(code: 418, message: "not json")

        #expect(TimelineChannel.remoteFailure(failure) == .callFailed(reasonCode: "callFailed", statusCode: 418, retryable: false))
    }

    @Test("provider resolution reports absence, ambiguity, and an unexpected provider")
    func providerResolution() {
        let id = UUID()
        let one = [entry(GnosticObjectType.timeline, id: id, provider: "Node-A")]
        let two = one + [entry(GnosticObjectType.timeline, id: id, provider: "node-b")]

        #expect(GnosticCatalogLookup.provider(of: GnosticObjectType.timeline, id: UUID(), in: one) == .unavailable)
        #expect(GnosticCatalogLookup.provider(of: GnosticObjectType.timeline, id: id, in: two) == .ambiguous)
        #expect(GnosticCatalogLookup.provider(of: GnosticObjectType.timeline, id: id, in: one, expected: "node-b") == .mismatch)
        #expect(GnosticCatalogLookup.provider(of: GnosticObjectType.timeline, id: id, in: one, expected: "node-a") == .provider("Node-A"))
    }

    @Test("capability checks match the operating Ascendant on the addressed provider")
    func operatingAscendantCapability() {
        let timelineID = UUID()
        let ascendantID = UUID()
        let entries = [
            entry(GnosticObjectType.timeline, id: timelineID, provider: "node-a", properties: [
                "attachedAscendantID": .string(ascendantID.uuidString),
            ]),
            entry(GnosticObjectType.ascendant, id: ascendantID, provider: "node-a", properties: [
                "capabilities": .array([.string(GnosticCapability.textTurnInput)]),
            ]),
        ]

        let operating = GnosticCatalogLookup.operatingAscendantID(ofTimeline: timelineID, providerID: "NODE-A", in: entries)
        #expect(operating == ascendantID)
        #expect(GnosticCatalogLookup.ascendantAdvertises(GnosticCapability.textTurnInput, ascendantID: ascendantID, providerID: "node-a", in: entries))
        #expect(!GnosticCatalogLookup.ascendantAdvertises(GnosticCapability.timelineManagement, providerID: "node-a", in: entries))
        #expect(!GnosticCatalogLookup.ascendantAdvertises(GnosticCapability.textTurnInput, providerID: "node-b", in: entries))
        #expect(GnosticCatalogLookup.operatingAscendantID(ofTimeline: timelineID, providerID: "node-b", in: entries) == nil)
    }

    private func entry(
        _ objectType: String,
        id: UUID,
        provider: String,
        properties: [String: NetworkDynamicValue] = [:]
    ) -> NetworkCatalogEntry {
        NetworkCatalogEntry(
            objectID: id,
            objectType: objectType,
            providerID: provider,
            name: "entry",
            knownProperties: properties,
            dynamicProperties: [:],
            workspace: nil
        )
    }
}
