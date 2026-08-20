// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Ascendant backend lifecycle")
struct BackendLifecycleTests {
    @Test("startup construction failure shuts down already-created backends")
    @MainActor
    func startupConstructionFailureRollsBackAllCreatedBackends() async throws {
        let firstID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000301")!
        let secondID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000302")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000303")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000304")!
        let probe = LifecycleBackendProbe()
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "lifecycle-fixture") { ascendant, _, _, timelines in
            let number = await probe.recordFactory()
            if number == 2 { throw InjectedLifecycleFailure() }
            return LifecycleFixtureBackend(ascendant: ascendant, timelines: timelines, probe: probe, outcome: .success)
        }
        let manifest = makeManifest(
            ascendants: [
                .init(id: firstID, name: "First", defaultTimelineID: firstTimelineID, kind: "lifecycle-fixture"),
                .init(id: secondID, name: "Second", defaultTimelineID: secondTimelineID, kind: "lifecycle-fixture"),
            ],
            timelines: [
                .init(id: firstTimelineID, title: "First", operatingAscendantID: firstID),
                .init(id: secondTimelineID, title: "Second", operatingAscendantID: secondID),
            ]
        )

        await #expect(throws: InjectedLifecycleFailure.self) {
            _ = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        }
        #expect(await probe.shutdownCount == 1)
    }

    @Test("one lifecycle failure is isolated and the next new Turn reconstructs only that Ascendant")
    @MainActor
    func lifecycleFailureIsolatedAndReconstructed() async throws {
        let firstID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000305")!
        let secondID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000306")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000307")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000308")!
        let probe = LifecycleBackendProbe()
        let adapters = makeAdapters(probe: probe, outcomes: [firstID: [.lifecycle, .success], secondID: [.success]])
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [
                    .init(id: firstID, name: "First", defaultTimelineID: firstTimelineID, kind: "lifecycle-fixture"),
                    .init(id: secondID, name: "Second", defaultTimelineID: secondTimelineID, kind: "lifecycle-fixture"),
                ],
                timelines: [
                    .init(id: firstTimelineID, title: "First", operatingAscendantID: firstID),
                    .init(id: secondTimelineID, title: "Second", operatingAscendantID: secondID),
                ]
            ).compileLaunchPlan(),
            adapters: adapters
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        do {
            _ = try await runtime.turn(.init(message: "first", timelineID: firstTimelineID, clientTurnID: "failed"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error == .lifecycleUnusable(timelineID: firstTimelineID, clientTurnID: "failed", detail: "backend lifecycle failed"))
        }
        #expect(await runtime.backendHealth(for: firstID) == .failed)
        #expect(await runtime.backendHealth(for: secondID) == .healthy)
        #expect(try await runtime.turn(.init(message: "unrelated", timelineID: secondTimelineID, clientTurnID: "unrelated")).text == "ok: unrelated")
        #expect(try await runtime.turn(.init(message: "recovered", timelineID: firstTimelineID, clientTurnID: "recovered")).text == "ok: recovered")
        #expect(await runtime.backendHealth(for: firstID) == .healthy)
        #expect(await probe.factoryCount == 3)
    }

    @Test("concurrent new Turns share one reconstruction flight")
    @MainActor
    func concurrentRecoveryIsSingleFlight() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000309")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000310")!
        let probe = LifecycleBackendProbe(blockSecondFactory: true)
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.lifecycle, .success]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        do {
            _ = try await runtime.turn(.init(message: "fail", timelineID: timelineID, clientTurnID: "fail"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error == .lifecycleUnusable(timelineID: timelineID, clientTurnID: "fail", detail: "backend lifecycle failed"))
        }
        let first = Task { @MainActor in
            try await runtime.turn(.init(message: "one", timelineID: timelineID, clientTurnID: "one"))
        }
        await probe.waitUntilFactoryCount(2)
        let second = Task { @MainActor in
            try await runtime.turn(.init(message: "two", timelineID: timelineID, clientTurnID: "two"))
        }
        await probe.releaseSecondFactory()
        #expect(try await first.value.text == "ok: one")
        #expect(try await second.value.text == "ok: two")
        #expect(await probe.factoryCount == 2)
    }

    @Test("failed reconstruction returns unavailable without rerunning the Turn operation")
    @MainActor
    func failedReconstructionIsStructuredAndBounded() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000311")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000312")!
        let probe = LifecycleBackendProbe(reconstructionFails: true)
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.lifecycle]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        do {
            _ = try await runtime.turn(.init(message: "fail", timelineID: timelineID, clientTurnID: "fail"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error == .lifecycleUnusable(timelineID: timelineID, clientTurnID: "fail", detail: "backend lifecycle failed"))
        }
        do {
            _ = try await runtime.turn(.init(message: "retry", timelineID: timelineID, clientTurnID: "retry"))
            Issue.record("The unavailable backend unexpectedly accepted a Turn.")
        } catch let error as AscendantTurnError {
            #expect(error == .backendUnavailable(timelineID: timelineID, clientTurnID: "retry", detail: "Backend reconstruction failed: reconstruction failed"))
        }
        #expect(await probe.factoryCount == 2)
        #expect(await probe.runCount == 1)
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
    }

    @Test("ordinary Turn failures do not quarantine the backend")
    @MainActor
    func ordinaryTurnFailureLeavesBackendHealthy() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000313")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000314")!
        let probe = LifecycleBackendProbe()
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.ordinary, .success]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        do {
            _ = try await runtime.turn(.init(message: "ordinary", timelineID: timelineID, clientTurnID: "ordinary"))
            Issue.record("The ordinary failure unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error == .terminal(timelineID: timelineID, clientTurnID: "ordinary", code: "ordinaryFailure", detail: "ordinary failure", retryable: false))
        }
        #expect(await runtime.backendHealth(for: ascendantID) == .healthy)
        #expect(try await runtime.turn(.init(message: "next", timelineID: timelineID, clientTurnID: "next")).text == "ok: next")
        #expect(await probe.factoryCount == 1)
    }

    private func makeAdapters(probe: LifecycleBackendProbe, outcomes: [UUID: [LifecycleFixtureBackend.Outcome]]) -> NodeRuntimeAdapters {
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "lifecycle-fixture") { ascendant, _, _, timelines in
            let number = await probe.recordFactory()
            if probe.shouldFailReconstruction && number > 1 {
                throw InjectedReconstructionFailure()
            }
            if number == 2, probe.shouldBlockSecondFactory {
                await probe.waitForSecondFactoryRelease()
            }
            let sequence = number == 1 ? (outcomes[ascendant.id] ?? []) : Array((outcomes[ascendant.id] ?? []).dropFirst())
            return LifecycleFixtureBackend(
                ascendant: ascendant,
                timelines: timelines,
                probe: probe,
                outcome: sequence.first ?? .success,
                outcomes: sequence
            )
        }
        return adapters
    }

    private func makeManifest(ascendants: [NodeManifest.Ascendant], timelines: [NodeManifest.Timeline]) -> NodeManifest {
        NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "backend-lifecycle-\(UUID().uuidString.lowercased())"),
            node: .init(id: UUID()),
            ascendants: ascendants,
            timelines: timelines
        )
    }
}

private struct InjectedLifecycleFailure: Error, Sendable, Equatable {}
private struct InjectedReconstructionFailure: Error, Sendable, Equatable, LocalizedError {
    var errorDescription: String? { "reconstruction failed" }
}

private actor LifecycleBackendProbe {
    private(set) var factoryCount = 0
    private(set) var shutdownCount = 0
    private(set) var runCount = 0
    let shouldBlockSecondFactory: Bool
    let shouldFailReconstruction: Bool
    private var secondFactoryReleased = false
    private var factoryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockSecondFactory: Bool = false, reconstructionFails: Bool = false) {
        shouldBlockSecondFactory = blockSecondFactory
        shouldFailReconstruction = reconstructionFails
    }

    func recordFactory() -> Int {
        factoryCount += 1
        if factoryCount >= 2 {
            factoryWaiters.forEach { $0.resume() }
            factoryWaiters.removeAll()
        }
        return factoryCount
    }

    func recordRun() { runCount += 1 }
    func recordShutdown() { shutdownCount += 1 }

    func waitUntilFactoryCount(_ count: Int) async {
        guard factoryCount < count else { return }
        await withCheckedContinuation { continuation in
            factoryWaiters.append(continuation)
        }
    }

    func waitForSecondFactoryRelease() async {
        guard !secondFactoryReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseSecondFactory() {
        secondFactoryReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

@MainActor
private final class LifecycleFixtureBackend: AscendantBackend {
    enum Outcome: Sendable, Equatable { case success, lifecycle, ordinary }

    let identity: AscendantBackendIdentity
    private let timelines: [AscendantBackendTimeline]
    private let probe: LifecycleBackendProbe
    private var outcomes: [Outcome]

    init(
        ascendant: NodeManifest.Ascendant,
        timelines: [NodeManifest.Timeline],
        probe: LifecycleBackendProbe,
        outcome: Outcome,
        outcomes: [Outcome] = []
    ) {
        let now = Date()
        identity = .init(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: .init(interoperability: [AscendantInteroperabilityCapability.textTurn.rawValue], backendKind: "lifecycle-fixture")
        )
        self.timelines = timelines.map {
            .init(id: $0.id, title: $0.title, attachedWorkspaceIDs: [], ascendantID: ascendant.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        }
        self.probe = probe
        self.outcomes = outcomes.isEmpty ? [outcome] : outcomes
    }

    func validateConfiguration() throws {}
    func operatedTimelines() async throws -> [AscendantBackendTimeline] { timelines }
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline { timelines[0] }
    func removeTimeline(id: UUID) async {}
    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline { timelines[0] }

    func runTurn(_ request: AscendantBackendTurnRequest, updates _: any AscendantBackendUpdateSink) async throws -> String {
        await probe.recordRun()
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        switch outcome {
        case .success: return "ok: \(request.message)"
        case .lifecycle: throw AscendantBackendError.lifecycleUnusable(.init(message: "backend lifecycle failed"))
        case .ordinary: throw AscendantBackendError.terminal(.init(code: "ordinaryFailure", message: "ordinary failure"))
        }
    }

    func cancel() async {}

    func shutdown() async {
        await probe.recordShutdown()
    }
}
