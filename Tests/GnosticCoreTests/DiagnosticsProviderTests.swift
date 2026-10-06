// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Diagnostics provider")
struct DiagnosticsProviderTests {
    private let nodeID = UUID(uuidString: "D1A60000-0000-4000-8000-000000000001")!
    private let ascendantID = UUID(uuidString: "D1A60000-0000-4000-8000-000000000002")!
    private let timelineID = UUID(uuidString: "D1A60000-0000-4000-8000-000000000003")!
    private let workspaceID = UUID(uuidString: "D1A60000-0000-4000-8000-000000000004")!

    private func nodeSnapshot() -> NodeDiagnostics {
        NodeDiagnostics(
            nodeID: nodeID,
            ascendents: [
                DiagnosticsAscendantSummary(
                    id: ascendantID,
                    name: "Ascendant",
                    health: .healthy,
                    quarantined: false
                ),
            ],
            timelines: [
                DiagnosticsTimelineSummary(id: timelineID, title: "Timeline", operatingAscendantID: ascendantID),
            ],
            workspaces: [
                DiagnosticsWorkspaceSummary(id: workspaceID, uri: "workspace://alpha", status: .available),
            ],
            turns: DiagnosticsTurnCounters(inFlight: 2, completed: 5, observationPending: 1, observationClosed: false),
            observer: DiagnosticsObserverDrain(
                liveObservations: 3,
                cleanupFailures: 0,
                retainedInFlight: 1,
                retainedCompleted: 4,
                retainedTombstones: 0
            )
        )
    }

    private func provider(
        node: @escaping DiagnosticsProvider.NodeExecutor = { fatalError("unused") },
        ascendant: @escaping DiagnosticsProvider.AscendantExecutor = { _ in fatalError("unused") },
        timeline: @escaping DiagnosticsProvider.TimelineExecutor = { _ in fatalError("unused") }
    ) -> DiagnosticsProvider {
        DiagnosticsProvider(node: node, ascendant: ascendant, timeline: timeline)
    }

    @Test("node diagnostics encode a payload-free snapshot")
    func nodeDiagnosticsEncodePayloadFreeSnapshot() async throws {
        let snapshot = nodeSnapshot()
        let result = try await provider(node: { snapshot })
            .handle(operation: DiagnosticsProvider.nodeOperation, parameters: encoded(DiagnosticsNodeRequest()))

        guard case let .success(payload, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        let decoded = try JSONDecoder().decode(NodeDiagnostics.self, from: Data(payload.utf8))
        #expect(decoded == snapshot)
        #expect(decoded.protocolMajor == GnosticProtocol.currentMajor)
        // The encoded result carries counts and identifiers only: no Turn body,
        // no secret value, and no raw wire payload field.
        #expect(!payload.contains("\"payload\""))
        #expect(!payload.contains("clientTurnID"))
        #expect(!payload.contains("text"))
    }

    @Test("ascendant and timeline diagnostics resolve their target")
    func targetDiagnosticsResolveTarget() async throws {
        let ascendant = AscendantDiagnostics(
            ascendant: DiagnosticsAscendantSummary(
                id: ascendantID,
                name: "Ascendant",
                health: .healthy,
                quarantined: false
            ),
            description: "Test ascendant",
            backendKind: "test",
            backendVersion: "1.0.0",
            capabilities: [GnosticCapability.textTurnInput, GnosticCapability.diagnostics],
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            timelines: []
        )
        let timeline = TimelineDiagnostics(
            timeline: DiagnosticsTimelineSummary(id: timelineID, title: "Timeline", operatingAscendantID: ascendantID),
            workspaces: []
        )
        let handler = provider(
            ascendant: { id in
                #expect(id == ascendantID)
                return ascendant
            },
            timeline: { id in
                #expect(id == timelineID)
                return timeline
            }
        )

        let ascendantResult = try await handler.handle(
            operation: DiagnosticsProvider.ascendantOperation,
            parameters: encoded(DiagnosticsTargetRequest(id: ascendantID))
        )
        guard case let .success(ascendantPayload, _) = ascendantResult else {
            Issue.record("expected ascendant success, got \(ascendantResult)")
            return
        }
        let decodedAscendant = try JSONDecoder().decode(AscendantDiagnostics.self, from: Data(ascendantPayload.utf8))
        #expect(decodedAscendant == ascendant)
        // Capabilities are filtered to the stable/experimental vocabulary and sorted.
        #expect(decodedAscendant.capabilities == decodedAscendant.capabilities.sorted())

        let timelineResult = try await handler.handle(
            operation: DiagnosticsProvider.timelineOperation,
            parameters: encoded(DiagnosticsTargetRequest(id: timelineID))
        )
        guard case let .success(timelinePayload, _) = timelineResult else {
            Issue.record("expected timeline success, got \(timelineResult)")
            return
        }
        let decodedTimeline = try JSONDecoder().decode(TimelineDiagnostics.self, from: Data(timelinePayload.utf8))
        #expect(decodedTimeline == timeline)
    }

    @Test("unknown operation returns 404")
    func unknownOperationReturnsNotFound() async throws {
        let result = try await provider().handle(operation: "me.atkn.gnostic.diagnostics.missing", parameters: nil)
        guard case let .failure(code, message, _) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(code == 404)
        #expect(message.contains("unknownDiagnosticsOperation"))
    }

    @Test("invalid payload returns 400")
    func invalidPayloadReturnsBadRequest() async throws {
        // A valid protocol envelope with a missing target field fails request
        // decoding, which is the diagnostics-specific 400 path.
        let result = try await provider().handle(
            operation: DiagnosticsProvider.ascendantOperation,
            parameters: "{\"protocolMajor\":\(GnosticProtocol.currentMajor)}"
        )
        guard case let .failure(code, message, _) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(code == 400)
        #expect(message.contains("invalidDiagnosticsPayload"))
    }

    @Test("a runtime error maps to a structured 404")
    func runtimeErrorMapsToStructuredNotFound() async throws {
        let missing = UUID()
        let result = try await provider(ascendant: { _ in throw NodeRuntimeError.unknownAscendant(missing) })
            .handle(
                operation: DiagnosticsProvider.ascendantOperation,
                parameters: encoded(DiagnosticsTargetRequest(id: missing))
            )
        guard case let .failure(code, message, _) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(code == 404)
        #expect(message.contains("unknownAscendant"))
    }

    private func encoded<T: Encodable>(_ value: T) -> String {
        String(decoding: try! GnosticWirePayload.encode(value, context: "test diagnostics payload"), as: UTF8.self)
    }
}
