// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

@Suite("Inspect diagnostics rendering")
struct InspectDiagnosticsRendererTests {
    private let ascendantID = UUID(uuidString: "D1A60000-0000-4000-8000-000000000002")!
    private let timelineID = UUID(uuidString: "D1A60000-0000-4000-8000-000000000003")!
    private let workspaceID = UUID(uuidString: "D1A60000-0000-4000-8000-000000000004")!

    private func nodeSnapshot() -> NodeDiagnostics {
        NodeDiagnostics(
            nodeID: UUID(uuidString: "D1A60000-0000-4000-8000-000000000001")!,
            ascendents: [
                DiagnosticsAscendantSummary(id: ascendantID, name: "Ascendant", health: .failed, quarantined: true),
            ],
            timelines: [
                DiagnosticsTimelineSummary(id: timelineID, title: "Timeline", operatingAscendantID: ascendantID),
            ],
            workspaces: [
                DiagnosticsWorkspaceSummary(id: workspaceID, uri: "workspace://alpha", status: .unavailable),
            ],
            turns: DiagnosticsTurnCounters(inFlight: 2, completed: 5, observationPending: 1, observationClosed: false),
            observer: DiagnosticsObserverDrain(
                liveObservations: 3,
                cleanupFailures: 1,
                retainedInFlight: 1,
                retainedCompleted: 4,
                retainedTombstones: 2
            )
        )
    }

    @Test("node text renders health, quarantine, and counts deterministically")
    func nodeTextRendersLiveState() {
        let text = InspectRenderer.nodeText(nodeSnapshot())
        #expect(text.contains("health=failed quarantined=true"))
        #expect(text.contains("turns  inFlight=2 completed=5 observationPending=1 observationClosed=false"))
        #expect(text.contains("observer  live=3 cleanupFailures=1 retainedInFlight=1 retainedCompleted=4 retainedTombstones=2"))
        #expect(text.contains(ascendantID.uuidString.lowercased()))
        #expect(text.contains(timelineID.uuidString.lowercased()))
        #expect(text.contains("workspace://alpha"))
        // Deterministic: rendering twice is byte-identical.
        #expect(text == InspectRenderer.nodeText(nodeSnapshot()))
    }

    @Test("diagnostics JSON carries the snapshot and a trailing newline")
    func diagnosticsJSONRoundTrips() throws {
        let snapshot = nodeSnapshot()
        let json = try InspectRenderer.diagnosticsJSON(snapshot)
        #expect(json.hasSuffix("}\n"))
        let decoded = try JSONDecoder().decode(NodeDiagnostics.self, from: Data(json.utf8))
        #expect(decoded == snapshot)
    }

    @Test("ascendant and timeline text render their payload-free summaries")
    func ascendantAndTimelineText() {
        let ascendant = AscendantDiagnostics(
            ascendant: DiagnosticsAscendantSummary(id: ascendantID, name: "Ascendant", health: .healthy, quarantined: false),
            description: "Test ascendant",
            backendKind: "test",
            backendVersion: "1.0.0",
            capabilities: [GnosticCapability.diagnostics],
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            timelines: []
        )
        let ascendantText = InspectRenderer.ascendantText(ascendant)
        #expect(ascendantText.contains("health=healthy quarantined=false"))
        #expect(ascendantText.contains("backend=test version=1.0.0"))
        #expect(ascendantText.contains(GnosticCapability.diagnostics))

        let timeline = TimelineDiagnostics(
            timeline: DiagnosticsTimelineSummary(id: timelineID, title: "Timeline", operatingAscendantID: ascendantID),
            workspaces: [DiagnosticsWorkspaceSummary(id: workspaceID, uri: "workspace://alpha", status: .available)]
        )
        let timelineText = InspectRenderer.timelineText(timeline)
        #expect(timelineText.contains("operator=\(ascendantID.uuidString.lowercased())"))
        #expect(timelineText.contains("available  uri=workspace://alpha"))
    }

    @Test("events never render the raw payload, only its byte count")
    func eventsNeverRenderPayload() throws {
        let secret = "sk-live-SUPERSECRET"
        let event = GnosticRawWireEvent(
            kind: .call,
            sourceId: "provider-a",
            correlationId: "corr-1",
            objectType: GnosticObjectType.ascendant,
            targetObjectId: ascendantID,
            channelId: "me.atkn.gnostic.channel.turn",
            payload: "{\"prompt\":\"\(secret)\"}"
        )

        let text = InspectRenderer.eventsText([event])
        #expect(text.contains("call"))
        #expect(text.contains("payloadBytes=\(event.payload.utf8.count)"))
        #expect(!text.contains(secret))

        let json = try InspectRenderer.eventsJSON([event])
        #expect(!json.contains(secret))
        #expect(!json.contains("\"payload\""))
        #expect(json.contains("\"payloadBytes\""))
        let decoded = try JSONDecoder().decode([RenderedWireEvent].self, from: Data(json.utf8))
        #expect(decoded == [RenderedWireEvent(event)])
    }

    @Test("empty event observations render a deterministic placeholder")
    func emptyEventsRenderPlaceholder() throws {
        #expect(InspectRenderer.eventsText([]) == "(no wire events observed)\n")
        let json = try InspectRenderer.eventsJSON([])
        let decoded = try JSONDecoder().decode([RenderedWireEvent].self, from: Data(json.utf8))
        #expect(decoded.isEmpty)
    }

    @Test("diagnostics errors map to stable CLI reason codes")
    func diagnosticsErrorsMapToCLIReasonCodes() {
        let missing = InspectError(.missingCapability(GnosticCapability.diagnostics))
        #expect(missing.reasonCode == "diagnosticsCapabilityUnavailable")
        #expect(missing.errorDescription?.contains(GnosticCapability.diagnostics) == true)

        let unavailable = InspectError(.ascendantUnavailable(ascendantID))
        #expect(unavailable.reasonCode == "ascendantUnavailable")

        let failed = InspectError(.callFailed(reasonCode: "diagnosticsConflict", statusCode: 409, retryable: false))
        #expect(failed.reasonCode == "diagnosticsUnavailable")
        #expect(failed.errorDescription?.contains("diagnosticsConflict") == true)
    }
}
