// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Runtime terminal observation integration")
struct RuntimeObservationIntegrationTests {
    @Test("the default runtime path has no live observation effect")
    @MainActor
    func absentObserverPreservesRuntimeBehavior() async throws {
        let timelineID = UUID()
        let ascendantID = UUID()
        let manifest = makeManifest(namespace: "runtime-observation-empty", ascendantID: ascendantID, timelineID: timelineID)
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "example-echo") { ascendant, _, _, timelines in
            EchoAscendantBackend(ascendant: ascendant, timelines: timelines)
        }

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await runtime.start()
        let result = try await runtime.turn(.init(message: "hello", timelineID: timelineID, clientTurnID: "empty-observer"))

        #expect(result.text == "echo: hello")
        let active = await runtime.observationSnapshot()
        #expect(active.state == .active)
        #expect(active.liveEffects.isEmpty)

        await runtime.shutdown()
        let disposed = await runtime.observationSnapshot()
        #expect(disposed.state == .disposed)
        #expect(disposed.liveEffects.isEmpty)
    }

    @Test("NodeRuntime adapters install one generic terminal observer")
    @MainActor
    func installedObserverReceivesOriginalTurnOnly() async throws {
        let timelineID = UUID()
        let ascendantID = UUID()
        let observer = RecordingTerminalObserver()
        let manifest = makeManifest(namespace: "runtime-observation-installed", ascendantID: ascendantID, timelineID: timelineID)
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "example-echo") { ascendant, _, _, timelines in
            EchoAscendantBackend(ascendant: ascendant, timelines: timelines)
        }
        adapters.terminalTurnObservers = [observer]

        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await runtime.start()
        let request = AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: "installed-observer")
        let first = try await runtime.turn(request)
        let replay = try await runtime.turn(request)

        let records = await observer.records
        #expect(first.text == "echo: hello")
        #expect(replay.replayed)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.ascendantID == ascendantID)
        #expect(record.timelineID == timelineID)
        #expect(record.clientTurnID == request.clientTurnID)
        #expect(record.outcome == .succeeded)
        #expect(!record.operationID.isEmpty)

        let snapshots = await runtime.allEffectSnapshots()
        let allowedScopes: Set<String> = [
            "gnostic-subscription", "turn-observation", "node-runtime-host",
            "turn-update-publisher", "network-resolution", "node-transport",
            "transport-registrations", "transport-responders", "transport-permission",
            "transport-advertisements",
        ]
        let allowedLabels: Set<String> = [
            "observe-ascendant", "observe-timeline", "observe-workspace", "observe-deadvertise",
            "turn-observation", "workspace-handler", "workspace-query-responder", "ascendant-turn",
            "ascendant-turn-replay", "permission-handler", "permission-observation", "timeline-status",
            "timeline-management", "workspace-operations", "discover-responder", "advertisement-teardown",
            "advertisements", "permission", "registrations", "responders", "turn-update-publisher",
            "network-resolution", "subscription", "transport",
        ]
        #expect(Set(snapshots.map(\.name)) == allowedScopes)
        #expect(Set(snapshots.flatMap(\.liveEffects).map(\.originScope)).isSubset(of: allowedScopes))
        #expect(Set(snapshots.flatMap(\.liveEffects).map(\.label)).isSubset(of: allowedLabels))
        #expect(snapshots.flatMap(\.liveEffects).allSatisfy { $0.label.utf8.count <= 64 })
        let host = try #require(snapshots.first { $0.name == "node-runtime-host" })
        #expect(Set(host.liveEffects.map(\.label)).isSuperset(of: ["subscription", "transport"]))

        await runtime.shutdown()
        #expect((await runtime.observationSnapshot()).state == .disposed)
    }

    private func makeManifest(namespace: String, ascendantID: UUID, timelineID: UUID) -> NodeManifest {
        NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Example", defaultTimelineID: timelineID, kind: "example-echo")],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
        )
    }
}

private actor RecordingTerminalObserver: TerminalTurnObserving {
    private(set) var records: [TerminalTurnRecord] = []

    func observe(_ record: TerminalTurnRecord) async throws {
        records.append(record)
    }
}
