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
            let number = await probe.recordFactory(timelines: timelines)
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

    @Test("operated timeline projection failure retires the created backend")
    @MainActor
    func operatedTimelineProjectionFailureRollsBackCreatedBackend() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000343")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000344")!
        let probe = LifecycleBackendProbe()
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "timeline-projection-failure") { ascendant, _, _, timelines in
            _ = await probe.recordFactory(timelines: timelines)
            return LifecycleFixtureBackend(
                ascendant: ascendant,
                timelines: timelines,
                probe: probe,
                outcome: .success,
                throwsFromOperatedTimelines: true
            )
        }
        let manifest = makeManifest(
            ascendants: [.init(id: ascendantID, name: "Projection failure", defaultTimelineID: timelineID, kind: "timeline-projection-failure")],
            timelines: [.init(id: timelineID, title: "Default", operatingAscendantID: ascendantID)]
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
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000310")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000315")!
        let probe = LifecycleBackendProbe(blockSecondFactory: true)
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: firstTimelineID, kind: "lifecycle-fixture")],
                timelines: [
                    .init(id: firstTimelineID, title: "First", operatingAscendantID: ascendantID),
                    .init(id: secondTimelineID, title: "Second", operatingAscendantID: ascendantID),
                ]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.lifecycle, .success]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        do {
            _ = try await runtime.turn(.init(message: "fail", timelineID: firstTimelineID, clientTurnID: "fail"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error == .lifecycleUnusable(timelineID: firstTimelineID, clientTurnID: "fail", detail: "backend lifecycle failed"))
        }
        let first = Task { @MainActor in
            try await runtime.turn(.init(message: "one", timelineID: firstTimelineID, clientTurnID: "one"))
        }
        try await withTestTimeout { await probe.waitUntilFactoryCount(2) }
        let second = Task { @MainActor in
            try await runtime.turn(.init(message: "two", timelineID: secondTimelineID, clientTurnID: "two"))
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

    @Test("Timeline mutations quarantine a backend after lifecycle failure")
    @MainActor
    func timelineMutationQuarantinesFailedBackend() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000316")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000317")!
        let probe = LifecycleBackendProbe(failRename: true)
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.success]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        await #expect(throws: AscendantBackendError.lifecycleUnusable(.init(code: "timelineLifecycle", message: "timeline backend failed"))) {
            _ = try await runtime.renameTimeline(.init(timelineID: timelineID, title: "Rejected"))
        }
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        #expect(await probe.renameCount == 1)
        await #expect(throws: NodeRuntimeError.unknownAscendant(ascendantID)) {
            _ = try await runtime.renameTimeline(.init(timelineID: timelineID, title: "Still rejected"))
        }
        #expect(await probe.renameCount == 1)
    }

    @Test("Workspace mutations quarantine a backend after lifecycle failure")
    @MainActor
    func workspaceMutationQuarantinesFailedBackend() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000318")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000319")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000320")!
        let probe = LifecycleBackendProbe(failWorkspaceAttach: true)
        let runtime = try await NodeRuntime(
            plan: NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "backend-workspace-lifecycle-\(UUID().uuidString.lowercased())"),
                node: .init(id: UUID()),
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)],
                workspaces: [.init(id: workspaceID, name: "Local", uri: "echo://local")]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.success]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        await #expect(throws: AscendantBackendError.lifecycleUnusable(.init(code: "workspaceLifecycle", message: "workspace backend failed"))) {
            _ = try await runtime.attachWorkspace(.init(workspaceID: workspaceID, timelineID: timelineID))
        }
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        #expect(await probe.workspaceAttachCount == 1)
        await #expect(throws: NodeRuntimeError.unknownAscendant(ascendantID)) {
            _ = try await runtime.attachWorkspace(.init(workspaceID: workspaceID, timelineID: timelineID))
        }
        #expect(await probe.workspaceAttachCount == 1)
    }

    @Test("an in-flight Timeline mutation is fenced by a same-instance backend replacement")
    @MainActor
    func inFlightTimelineMutationIsFencedByBackendReplacement() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000352")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000353")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000354")!
        let recoveryTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000355")!
        let probe = LifecycleBackendProbe(
            failRename: true,
            successfulRecovery: true,
            reuseBackendOnReconstruction: true,
            blockedOperation: "create"
        )
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: firstTimelineID, kind: "lifecycle-fixture")],
                timelines: [
                    .init(id: firstTimelineID, title: "First", operatingAscendantID: ascendantID),
                    .init(id: secondTimelineID, title: "Second", operatingAscendantID: ascendantID),
                    .init(id: recoveryTimelineID, title: "Recovery", operatingAscendantID: ascendantID),
                ]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: []])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let blocked = Task { @MainActor in
            try? await runtime.createTimeline(title: "blocked", ascendantID: ascendantID)
        }
        try await withTestTimeout { await probe.waitUntilBlockedOperationStarted("create") }

        do {
            _ = try await runtime.renameTimeline(.init(timelineID: secondTimelineID, title: "quarantine"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch {}
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        do {
            _ = try await runtime.turn(.init(message: "recovery-reused", timelineID: recoveryTimelineID, clientTurnID: "recovery-reused"))
            Issue.record("A retired backend instance was accepted as a replacement.")
        } catch {}
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        #expect(await probe.factoryCount == 2)
        #expect(await probe.reusedBackendCount == 1)
        #expect(try await runtime.turn(.init(message: "recovery", timelineID: recoveryTimelineID, clientTurnID: "recovery")).text == "ok: recovery")
        #expect(await probe.factoryCount == 3)
        await probe.releaseBlockedOperation()
        #expect(await blocked.value == nil)
        let blockedTimelineID = try #require(await probe.createdTimelineIDs.first)
        #expect(await probe.latestBackendContainsTimeline(blockedTimelineID) == false)
    }

    @Test("an in-flight Workspace mutation is fenced by a same-instance backend replacement")
    @MainActor
    func inFlightWorkspaceMutationIsFencedByBackendReplacement() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000356")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000357")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000358")!
        let recoveryTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000359")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000360")!
        let probe = LifecycleBackendProbe(
            failWorkspaceAttach: true,
            successfulRecovery: true,
            reuseBackendOnReconstruction: true,
            blockedOperation: "detach"
        )
        let runtime = try await NodeRuntime(
            plan: NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "backend-workspace-replacement-\(UUID().uuidString.lowercased())"),
                node: .init(id: UUID()),
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: firstTimelineID, kind: "lifecycle-fixture")],
                timelines: [
                    .init(id: firstTimelineID, title: "First", operatingAscendantID: ascendantID, attachments: [.local(workspaceID)]),
                    .init(id: secondTimelineID, title: "Second", operatingAscendantID: ascendantID),
                    .init(id: recoveryTimelineID, title: "Recovery", operatingAscendantID: ascendantID),
                ],
                workspaces: [.init(id: workspaceID, name: "Local", uri: "echo://local")]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: []])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let blocked = Task { @MainActor in
            try? await runtime.detachWorkspace(.init(workspaceID: workspaceID, timelineID: firstTimelineID))
        }
        try await withTestTimeout { await probe.waitUntilBlockedOperationStarted("detach") }

        do {
            _ = try await runtime.attachWorkspace(.init(workspaceID: workspaceID, timelineID: secondTimelineID))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch {}
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        do {
            _ = try await runtime.turn(.init(message: "recovery-reused", timelineID: recoveryTimelineID, clientTurnID: "recovery-reused"))
            Issue.record("A retired backend instance was accepted as a replacement.")
        } catch {}
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        #expect(await probe.factoryCount == 2)
        #expect(await probe.reusedBackendCount == 1)
        #expect(try await runtime.turn(.init(message: "recovery", timelineID: recoveryTimelineID, clientTurnID: "recovery")).text == "ok: recovery")
        #expect(await probe.factoryCount == 3)
        await probe.releaseBlockedOperation()
        #expect(await blocked.value == nil)
        #expect(await probe.latestBackendContainsWorkspace(workspaceID, on: firstTimelineID))
    }

    @Test("reconstruction rehydrates current registry Timelines and attachment intent")
    @MainActor
    func reconstructionUsesCurrentRegistryState() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000321")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000322")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000323")!
        let probe = LifecycleBackendProbe()
        let runtime = try await NodeRuntime(
            plan: NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "backend-registry-state-\(UUID().uuidString.lowercased())"),
                node: .init(id: UUID()),
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)],
                workspaces: [.init(id: workspaceID, name: "Local", uri: "echo://local")]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.lifecycle, .success]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let dynamic = try await runtime.createTimeline(title: "Dynamic", ascendantID: ascendantID)
        _ = try await runtime.attachWorkspace(.init(workspaceID: workspaceID, timelineID: dynamic.timelineID))
        do {
            _ = try await runtime.turn(.init(message: "fail", timelineID: timelineID, clientTurnID: "state-fail"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch let error as AscendantTurnError {
            #expect(error == .lifecycleUnusable(timelineID: timelineID, clientTurnID: "state-fail", detail: "backend lifecycle failed"))
        }

        _ = try await runtime.turn(.init(message: "recovered", timelineID: timelineID, clientTurnID: "state-recovered"))
        let factoryIndex = 1
        let allFactoryTimelineIDs = await probe.factoryTimelineIDs
        let allFactoryAttachmentIDs = await probe.factoryAttachmentIDs
        let timelineIDs = allFactoryTimelineIDs[factoryIndex]
        let attachmentIDs = allFactoryAttachmentIDs[factoryIndex]
        #expect(timelineIDs.contains(dynamic.timelineID))
        if let dynamicIndex = timelineIDs.firstIndex(of: dynamic.timelineID) {
            #expect(attachmentIDs[dynamicIndex] == [workspaceID])
        } else {
            Issue.record("The dynamic Timeline was not supplied to reconstruction.")
        }
    }

    @Test("shutdown does not await a noncooperative backend reconstruction")
    @MainActor
    func shutdownDoesNotWaitForBlockedReconstruction() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000324")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000325")!
        let probe = LifecycleBackendProbe(blockSecondFactory: true)
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.lifecycle, .success]])
        )
        try await runtime.start()

        do {
            _ = try await runtime.turn(.init(message: "fail", timelineID: timelineID, clientTurnID: "blocked-fail"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch {}
        let recovery = Task { @MainActor in
            try? await runtime.turn(.init(message: "recovery", timelineID: timelineID, clientTurnID: "blocked-recovery"))
        }
        try await withTestTimeout { await probe.waitUntilFactoryCount(2) }
        let shutdown = Task { @MainActor in
            await runtime.shutdown()
            await probe.markShutdownFinished()
        }
        try await withTestTimeout { await probe.waitUntilShutdownFinished() }
        await probe.releaseSecondFactory()
        _ = await recovery.value
        await shutdown.value
        #expect(await runtime.backendHealth(for: ascendantID) != .healthy)
    }

    @Test("shutdown is not held by a noncooperative backend retirement")
    @MainActor
    func shutdownDoesNotWaitForNoncooperativeBackendRetirement() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000338")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000339")!
        let backendProbe = LifecycleBackendProbe(blockFirstShutdown: true)
        let deadline = ManualShutdownDeadline()
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: backendProbe, outcomes: [ascendantID: [.success]]),
            retirementPolicy: BackendRetirementPolicy(waitForBudget: { await deadline.wait() })
        )
        try await runtime.start()

        let shutdown = Task { @MainActor in
            await runtime.shutdown()
            await backendProbe.markShutdownFinished()
        }
        let concurrentShutdown = Task { @MainActor in
            await runtime.shutdown()
            await backendProbe.markShutdownFinished()
        }
        try await withTestTimeout { await backendProbe.waitUntilFirstShutdownStarted() }
        await deadline.release()
        try await withTestTimeout { await backendProbe.waitUntilShutdownFinished() }

        #expect(await runtime.backendHealth(for: ascendantID) != .healthy)
        await backendProbe.releaseFirstShutdown()
        await shutdown.value
        await concurrentShutdown.value
        try await withTestTimeout { await backendProbe.waitUntilShutdownCount(1) }
    }

    @Test("shutdown is not held by a noncooperative backend cancel")
    @MainActor
    func shutdownDoesNotWaitForNoncooperativeBackendCancel() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000340")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000341")!
        let backendProbe = LifecycleBackendProbe(blockFirstCancel: true)
        let deadline = ManualShutdownDeadline()
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: backendProbe, outcomes: [ascendantID: [.success]]),
            retirementPolicy: BackendRetirementPolicy(waitForBudget: { await deadline.wait() })
        )
        try await runtime.start()

        let shutdown = Task { @MainActor in
            await runtime.shutdown()
            await backendProbe.markShutdownFinished()
        }
        try await withTestTimeout { await backendProbe.waitUntilFirstCancelStarted() }
        await deadline.release()
        try await withTestTimeout { await backendProbe.waitUntilShutdownFinished() }

        #expect(await backendProbe.shutdownCount == 1)
        await backendProbe.releaseFirstCancel()
        await shutdown.value
        try await withTestTimeout { await backendProbe.waitUntilShutdownCount(1) }
    }

    @Test("initialization rollback bounds noncooperative backend cancellation")
    @MainActor
    func initializationRollbackDoesNotWaitForNoncooperativeCancel() async throws {
        let firstID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000342")!
        let secondID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000343")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000344")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000345")!
        let backendProbe = LifecycleBackendProbe(blockFirstCancel: true, failSecondFactory: true)
        let deadline = ManualShutdownDeadline()
        let construction = Task { @MainActor in
            do {
                _ = try await NodeRuntime(
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
                    adapters: makeAdapters(probe: backendProbe, outcomes: [firstID: [.success]]),
                    retirementPolicy: BackendRetirementPolicy(waitForBudget: { await deadline.wait() })
                )
                await backendProbe.markShutdownFinished()
                return false
            } catch {
                await backendProbe.markShutdownFinished()
                return true
            }
        }

        try await withTestTimeout { await backendProbe.waitUntilFirstCancelStarted() }
        await deadline.release()
        try await withTestTimeout { await backendProbe.waitUntilShutdownFinished() }
        #expect(await construction.value)
        #expect(await backendProbe.shutdownCount == 1)

        await backendProbe.releaseFirstCancel()
        try await withTestTimeout { await backendProbe.waitUntilShutdownCount(1) }
    }

    @Test("discarded reconstruction candidate retirement is bounded")
    @MainActor
    func discardedReconstructionCandidateRetirementIsBounded() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000346")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000347")!
        let backendProbe = LifecycleBackendProbe(blockSecondFactory: true, blockSecondShutdown: true)
        let deadline = ManualShutdownDeadline()
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: backendProbe, outcomes: [ascendantID: [.lifecycle, .success]]),
            retirementPolicy: BackendRetirementPolicy(waitForBudget: { await deadline.wait() })
        )
        try await runtime.start()
        do {
            _ = try await runtime.turn(.init(message: "fail", timelineID: timelineID, clientTurnID: "discarded-fail"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch {}

        let recovery = Task { @MainActor in
            try? await runtime.turn(.init(message: "recovery", timelineID: timelineID, clientTurnID: "discarded-recovery"))
        }
        try await withTestTimeout { await backendProbe.waitUntilFactoryCount(2) }
        let shutdown = Task { @MainActor in
            await runtime.shutdown()
            await backendProbe.markShutdownFinished()
        }
        await backendProbe.releaseSecondFactory()
        try await withTestTimeout { await backendProbe.waitUntilSecondShutdownStarted() }
        try await withTestTimeout { await backendProbe.waitUntilShutdownFinished() }
        await deadline.release()
        _ = await recovery.value
        await shutdown.value
        await backendProbe.releaseSecondShutdown()
        try await withTestTimeout { await backendProbe.waitUntilShutdownCount(2) }
    }

    @Test("an in-flight Turn cannot publish after shutdown")
    @MainActor
    func inFlightTurnIsFencedByShutdown() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000326")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000327")!
        let probe = LifecycleBackendProbe(blockRun: true)
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "First", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.success]])
        )
        try await runtime.start()

        let turn = Task { @MainActor in
            try? await runtime.turn(.init(message: "blocked", timelineID: timelineID, clientTurnID: "blocked"))
        }
        try await withTestTimeout { await probe.waitUntilRunStarted() }
        let shutdown = Task { @MainActor in
            await runtime.shutdown()
            await probe.markShutdownFinished()
        }
        try await withTestTimeout { await probe.waitUntilShutdownFinished() }
        await probe.releaseRun()

        #expect(await turn.value == nil)
        await shutdown.value
    }

    @Test("an in-flight Turn is fenced when its backend is replaced")
    @MainActor
    func inFlightTurnIsFencedByBackendReplacement() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000348")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000349")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000350")!
        let recoveryTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000351")!
        let probe = LifecycleBackendProbe(
            blockFirstRun: true,
            successfulRecovery: true,
            reuseBackendOnReconstruction: true
        )
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: firstTimelineID, kind: "lifecycle-fixture")],
                timelines: [
                    .init(id: firstTimelineID, title: "First", operatingAscendantID: ascendantID),
                    .init(id: secondTimelineID, title: "Second", operatingAscendantID: ascendantID),
                    .init(id: recoveryTimelineID, title: "Recovery", operatingAscendantID: ascendantID),
                ]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.success, .lifecycle]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let blocked = Task { @MainActor in
            try? await runtime.turn(.init(message: "blocked", timelineID: firstTimelineID, clientTurnID: "blocked"))
        }
        try await withTestTimeout { await probe.waitUntilRunStarted() }

        do {
            _ = try await runtime.turn(.init(message: "quarantine", timelineID: secondTimelineID, clientTurnID: "quarantine"))
            Issue.record("The lifecycle failure unexpectedly succeeded.")
        } catch {}
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)

        do {
            _ = try await runtime.turn(.init(message: "recovery-reused", timelineID: recoveryTimelineID, clientTurnID: "recovery-reused"))
            Issue.record("A retired backend instance was accepted as a replacement.")
        } catch {}
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)
        #expect(await probe.factoryCount == 2)
        #expect(await probe.reusedBackendCount == 1)
        #expect(try await runtime.turn(.init(message: "recovery", timelineID: recoveryTimelineID, clientTurnID: "recovery")).text == "ok: recovery")
        #expect(await probe.factoryCount == 3)
        await probe.releaseRun()
        #expect(await blocked.value == nil)
    }

    @Test("a late lifecycle failure from an old backend cannot quarantine its replacement")
    @MainActor
    func lateFailureFromOldBackendCannotQuarantineReplacement() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000328")!
        let firstTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000329")!
        let secondTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000330")!
        let recoveryTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000331")!
        let probe = LifecycleBackendProbe(
            blockFirstShutdown: true,
            blockSecondLifecycle: true,
            successfulRecovery: true
        )
        let runtime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: firstTimelineID, kind: "lifecycle-fixture")],
                timelines: [
                    .init(id: firstTimelineID, title: "First", operatingAscendantID: ascendantID),
                    .init(id: secondTimelineID, title: "Second", operatingAscendantID: ascendantID),
                    .init(id: recoveryTimelineID, title: "Recovery", operatingAscendantID: ascendantID),
                ]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: probe, outcomes: [ascendantID: [.lifecycle, .lifecycle]])
        )
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let first = Task { @MainActor in
            try? await runtime.turn(.init(message: "first", timelineID: firstTimelineID, clientTurnID: "old-first"))
        }
        await probe.waitUntilRunCount(1)
        let second = Task { @MainActor in
            try? await runtime.turn(.init(message: "second", timelineID: secondTimelineID, clientTurnID: "old-second"))
        }
        await probe.waitUntilRunCount(2)
        await probe.waitUntilFirstShutdownStarted()

        let recovery = Task { @MainActor in
            try? await runtime.turn(.init(message: "recovery", timelineID: recoveryTimelineID, clientTurnID: "replacement"))
        }
        #expect(await recovery.value?.text == "ok: recovery")
        #expect(await runtime.backendHealth(for: ascendantID) == .healthy)

        await probe.releaseSecondLifecycle()
        await probe.releaseFirstShutdown()
        _ = await first.value
        _ = await second.value
        #expect(await runtime.backendHealth(for: ascendantID) == .healthy)
        #expect(try await runtime.turn(.init(message: "still healthy", timelineID: recoveryTimelineID, clientTurnID: "still-healthy")).text == "ok: still healthy")
    }

    @Test("late Timeline rename and create completions cannot project after shutdown")
    @MainActor
    func lateTimelineCompletionsAreFencedAfterShutdown() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000332")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000333")!
        let renameProbe = LifecycleBackendProbe(blockedOperation: "rename")
        let renameRuntime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "Before", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: renameProbe, outcomes: [ascendantID: [.success]])
        )
        try await renameRuntime.start()
        let rename = Task { @MainActor in
            try? await renameRuntime.renameTimeline(.init(timelineID: timelineID, title: "Late rename"))
        }
        await renameProbe.waitUntilBlockedOperationStarted("rename")
        await renameRuntime.shutdown()
        await renameProbe.releaseBlockedOperation()
        #expect(await rename.value == nil)
        #expect(await renameRuntime.timeline(id: timelineID)?.title == "Before")

        let createTimelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000334")!
        let createProbe = LifecycleBackendProbe(blockedOperation: "create")
        let createRuntime = try await NodeRuntime(
            plan: makeManifest(
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: createTimelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: createTimelineID, title: "Before", operatingAscendantID: ascendantID)]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: createProbe, outcomes: [ascendantID: [.success]])
        )
        try await createRuntime.start()
        let create = Task { @MainActor in
            try? await createRuntime.createTimeline(title: "Late create", ascendantID: ascendantID)
        }
        await createProbe.waitUntilBlockedOperationStarted("create")
        await createRuntime.shutdown()
        await createProbe.releaseBlockedOperation()
        #expect(await create.value == nil)
        #expect(await createRuntime.snapshot().timelineIDs == [createTimelineID])
    }

    @Test("late Workspace attach and detach completions cannot project after shutdown")
    @MainActor
    func lateWorkspaceCompletionsAreFencedAfterShutdown() async throws {
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000335")!
        let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000336")!
        let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000337")!
        let attachProbe = LifecycleBackendProbe(blockedOperation: "attach")
        let attachRuntime = try await NodeRuntime(
            plan: NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "late-workspace-attach-(UUID().uuidString.lowercased())"),
                node: .init(id: UUID()),
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "Before", operatingAscendantID: ascendantID)],
                workspaces: [.init(id: workspaceID, name: "Local", uri: "echo://local")]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: attachProbe, outcomes: [ascendantID: [.success]])
        )
        try await attachRuntime.start()
        let attach = Task { @MainActor in
            try? await attachRuntime.attachWorkspace(.init(workspaceID: workspaceID, timelineID: timelineID))
        }
        await attachProbe.waitUntilBlockedOperationStarted("attach")
        await attachRuntime.shutdown()
        await attachProbe.releaseBlockedOperation()
        #expect(await attach.value == nil)
        #expect(await attachRuntime.timeline(id: timelineID)?.attachedWorkspaceIDs.isEmpty == true)

        let detachProbe = LifecycleBackendProbe(blockedOperation: "detach")
        let detachRuntime = try await NodeRuntime(
            plan: NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "late-workspace-detach-(UUID().uuidString.lowercased())"),
                node: .init(id: UUID()),
                ascendants: [.init(id: ascendantID, name: "First", defaultTimelineID: timelineID, kind: "lifecycle-fixture")],
                timelines: [.init(id: timelineID, title: "Before", operatingAscendantID: ascendantID, attachments: [.local(workspaceID)])],
                workspaces: [.init(id: workspaceID, name: "Local", uri: "echo://local")]
            ).compileLaunchPlan(),
            adapters: makeAdapters(probe: detachProbe, outcomes: [ascendantID: [.success]])
        )
        try await detachRuntime.start()
        let detach = Task { @MainActor in
            try? await detachRuntime.detachWorkspace(.init(workspaceID: workspaceID, timelineID: timelineID))
        }
        await detachProbe.waitUntilBlockedOperationStarted("detach")
        await detachRuntime.shutdown()
        await detachProbe.releaseBlockedOperation()
        #expect(await detach.value == nil)
        #expect(await detachRuntime.timeline(id: timelineID)?.attachedWorkspaceIDs == [workspaceID])
    }

    private func makeAdapters(probe: LifecycleBackendProbe, outcomes: [UUID: [LifecycleFixtureBackend.Outcome]]) -> NodeRuntimeAdapters {
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(kind: "lifecycle-fixture") { ascendant, _, _, timelines in
            let number = await probe.recordFactory(timelines: timelines)
            if probe.shouldFailSecondFactory && number == 2 {
                throw InjectedLifecycleFailure()
            }
            if probe.shouldFailReconstruction && number > 1 {
                throw InjectedReconstructionFailure()
            }
            if number == 2, probe.shouldBlockSecondFactory {
                await probe.waitForSecondFactoryRelease()
            }
            if number == 2, probe.shouldReuseBackendOnReconstruction,
               let backend = await probe.reusableBackend() {
                await probe.recordReusedBackend()
                await probe.recordCreatedBackend(backend)
                return backend
            }
            let sequence = number == 1
                ? (outcomes[ascendant.id] ?? [])
                : (probe.shouldUseSuccessfulRecovery ? [.success] : Array((outcomes[ascendant.id] ?? []).dropFirst()))
            let backend = LifecycleFixtureBackend(
                ascendant: ascendant,
                timelines: timelines,
                probe: probe,
                outcome: sequence.first ?? .success,
                outcomes: sequence,
                factoryNumber: number
            )
            if number == 1, probe.shouldReuseBackendOnReconstruction {
                await probe.retainReusableBackend(backend)
            }
            await probe.recordCreatedBackend(backend)
            return backend
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

private struct TestWaitTimedOut: Error, Sendable {}

private actor TestWaitArbiter {
    private var result: Result<Void, TestWaitTimedOut>?
    private var waiter: CheckedContinuation<Result<Void, TestWaitTimedOut>, Never>?

    func wait() async -> Result<Void, TestWaitTimedOut> {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func succeed() {
        resolve(.success(()))
    }

    func timeOut() {
        resolve(.failure(TestWaitTimedOut()))
    }

    private func resolve(_ result: Result<Void, TestWaitTimedOut>) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}

private func withTestTimeout(
    _ duration: Duration = .seconds(5),
    operation: @escaping @Sendable () async -> Void
) async throws {
    let arbiter = TestWaitArbiter()
    let operationTask = Task {
        await operation()
        await arbiter.succeed()
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: duration)
        guard !Task.isCancelled else { return }
        await arbiter.timeOut()
    }
    let result = await arbiter.wait()
    operationTask.cancel()
    timeoutTask.cancel()
    try result.get()
}

private actor ManualShutdownDeadline {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor LifecycleBackendProbe {
    private(set) var factoryCount = 0
    private(set) var shutdownCount = 0
    private(set) var runCount = 0
    private(set) var renameCount = 0
    private(set) var workspaceAttachCount = 0
    private(set) var reusedBackendCount = 0
    private(set) var createdTimelineIDs: [UUID] = []
    private(set) var factoryTimelineIDs: [[UUID]] = []
    private(set) var factoryAttachmentIDs: [[[UUID]]] = []
    private(set) var shutdownFinished = false
    let shouldBlockSecondFactory: Bool
    let shouldFailReconstruction: Bool
    let shouldFailWorkspaceAttach: Bool
    let shouldFailRename: Bool
    let shouldBlockRun: Bool
    let shouldBlockFirstRun: Bool
    let shouldBlockFirstShutdown: Bool
    let shouldBlockSecondShutdown: Bool
    let shouldBlockFirstCancel: Bool
    let shouldFailSecondFactory: Bool
    let shouldBlockSecondLifecycle: Bool
    let shouldUseSuccessfulRecovery: Bool
    let shouldReuseBackendOnReconstruction: Bool
    private var retainedBackend: LifecycleFixtureBackend?
    private var latestBackend: LifecycleFixtureBackend?
    private var blockedOperation: String?
    private var blockedOperationStarted = false
    private var blockedOperationReleased = false
    private var secondFactoryReleased = false
    private var secondLifecycleReleased = false
    private var firstShutdownReleased = false
    private var secondShutdownReleased = false
    private var firstCancelReleased = false
    private var runStarted = false
    private var runReleased = false
    private var firstShutdownStarted = false
    private var secondShutdownStarted = false
    private var firstCancelStarted = false
    private var factoryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstShutdownReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var runWaiters: [CheckedContinuation<Void, Never>] = []
    private var runReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var runCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var secondLifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstShutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondShutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCancelReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondShutdownReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedOperationReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        blockSecondFactory: Bool = false,
        reconstructionFails: Bool = false,
        failWorkspaceAttach: Bool = false,
        failRename: Bool = false,
        blockRun: Bool = false,
        blockFirstRun: Bool = false,
        blockFirstShutdown: Bool = false,
        blockSecondShutdown: Bool = false,
        blockFirstCancel: Bool = false,
        failSecondFactory: Bool = false,
        blockSecondLifecycle: Bool = false,
        successfulRecovery: Bool = false,
        reuseBackendOnReconstruction: Bool = false,
        blockedOperation: String? = nil
    ) {
        shouldBlockSecondFactory = blockSecondFactory
        shouldFailReconstruction = reconstructionFails
        shouldFailWorkspaceAttach = failWorkspaceAttach
        shouldFailRename = failRename
        shouldBlockRun = blockRun
        shouldBlockFirstRun = blockFirstRun
        shouldBlockFirstShutdown = blockFirstShutdown
        shouldBlockSecondShutdown = blockSecondShutdown
        shouldBlockFirstCancel = blockFirstCancel
        shouldFailSecondFactory = failSecondFactory
        shouldBlockSecondLifecycle = blockSecondLifecycle
        shouldUseSuccessfulRecovery = successfulRecovery
        shouldReuseBackendOnReconstruction = reuseBackendOnReconstruction
        self.blockedOperation = blockedOperation
    }

    func retainReusableBackend(_ backend: LifecycleFixtureBackend) {
        retainedBackend = backend
    }

    func reusableBackend() -> LifecycleFixtureBackend? {
        retainedBackend
    }

    func recordReusedBackend() {
        reusedBackendCount += 1
    }

    func recordCreatedBackend(_ backend: LifecycleFixtureBackend) {
        latestBackend = backend
    }

    func recordCreatedTimeline(_ id: UUID) {
        createdTimelineIDs.append(id)
    }

    func latestBackendContainsTimeline(_ id: UUID) async -> Bool {
        guard let latestBackend,
              let timelines = try? await latestBackend.operatedTimelines() else { return false }
        return timelines.contains { $0.id == id }
    }

    func latestBackendContainsWorkspace(_ workspaceID: UUID, on timelineID: UUID) async -> Bool {
        guard let latestBackend,
              let timelines = try? await latestBackend.operatedTimelines(),
              let timeline = timelines.first(where: { $0.id == timelineID }) else { return false }
        return timeline.attachedWorkspaceIDs.contains(workspaceID)
    }

    func recordFactory(timelines: [NodeManifest.Timeline] = []) -> Int {
        factoryCount += 1
        factoryTimelineIDs.append(timelines.map(\.id))
        factoryAttachmentIDs.append(timelines.map { $0.attachments.map(\.workspaceID) })
        if factoryCount >= 2 {
            factoryWaiters.forEach { $0.resume() }
            factoryWaiters.removeAll()
        }
        return factoryCount
    }

    func recordRun() {
        runCount += 1
        let ready = runCountWaiters.filter { $0.0 <= runCount }
        runCountWaiters.removeAll { $0.0 <= runCount }
        ready.forEach { $0.1.resume() }
    }
    func recordRename() { renameCount += 1 }
    func recordWorkspaceAttach() { workspaceAttachCount += 1 }
    func markShutdownFinished() {
        shutdownFinished = true
        shutdownWaiters.forEach { $0.resume() }
        shutdownWaiters.removeAll()
    }
    func recordShutdown() {
        shutdownCount += 1
        let ready = shutdownCountWaiters.filter { $0.0 <= shutdownCount }
        shutdownCountWaiters.removeAll { $0.0 <= shutdownCount }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilShutdownCount(_ count: Int) async {
        guard shutdownCount < count else { return }
        await withCheckedContinuation { continuation in
            shutdownCountWaiters.append((count, continuation))
        }
    }

    func waitUntilFactoryCount(_ count: Int) async {
        guard factoryCount < count else { return }
        await withCheckedContinuation { continuation in
            factoryWaiters.append(continuation)
        }
    }

    func waitUntilRunCount(_ count: Int) async {
        guard runCount < count else { return }
        await withCheckedContinuation { continuation in
            runCountWaiters.append((count, continuation))
        }
    }

    func beginBlockedOperation(_ operation: String) {
        guard blockedOperation == operation else { return }
        blockedOperationStarted = true
        blockedOperationWaiters.forEach { $0.resume() }
        blockedOperationWaiters.removeAll()
    }

    func waitUntilBlockedOperationStarted(_ operation: String) async {
        guard blockedOperation == operation, !blockedOperationStarted else { return }
        await withCheckedContinuation { continuation in
            blockedOperationWaiters.append(continuation)
        }
    }

    func waitForBlockedOperationRelease(_ operation: String) async {
        guard blockedOperation == operation, !blockedOperationReleased else { return }
        await withCheckedContinuation { continuation in
            blockedOperationReleaseWaiters.append(continuation)
        }
    }

    func releaseBlockedOperation() {
        blockedOperationReleased = true
        blockedOperationReleaseWaiters.forEach { $0.resume() }
        blockedOperationReleaseWaiters.removeAll()
    }

    func waitForSecondFactoryRelease() async {
        guard !secondFactoryReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForRunReleaseIfNeeded() async {
        guard (shouldBlockRun || (shouldBlockFirstRun && runCount == 1)), !runReleased else { return }
        runStarted = true
        runWaiters.forEach { $0.resume() }
        runWaiters.removeAll()
        await withCheckedContinuation { continuation in
            runReleaseWaiters.append(continuation)
        }
    }

    func waitForLifecycleReleaseIfNeeded(_ isLifecycleFailure: Bool) async {
        guard isLifecycleFailure, shouldBlockSecondLifecycle, runCount == 2, !secondLifecycleReleased else { return }
        await withCheckedContinuation { continuation in
            secondLifecycleWaiters.append(continuation)
        }
    }

    func waitUntilRunStarted() async {
        guard shouldBlockRun || shouldBlockFirstRun else { return }
        guard runStarted else {
            await withCheckedContinuation { continuation in
                runWaiters.append(continuation)
            }
            return
        }
    }

    func waitUntilShutdownFinished() async {
        guard !shutdownFinished else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    func recordFirstShutdownStarted() {
        firstShutdownStarted = true
        firstShutdownWaiters.forEach { $0.resume() }
        firstShutdownWaiters.removeAll()
    }

    func recordShutdownStarted(_ factoryNumber: Int) {
        if factoryNumber == 1, shouldBlockFirstShutdown {
            recordFirstShutdownStarted()
        } else if factoryNumber == 2, shouldBlockSecondShutdown {
            secondShutdownStarted = true
            secondShutdownWaiters.forEach { $0.resume() }
            secondShutdownWaiters.removeAll()
        }
    }

    func waitUntilFirstShutdownStarted() async {
        guard !firstShutdownStarted else { return }
        await withCheckedContinuation { continuation in
            firstShutdownWaiters.append(continuation)
        }
    }

    func waitUntilSecondShutdownStarted() async {
        guard !secondShutdownStarted else { return }
        await withCheckedContinuation { continuation in
            secondShutdownWaiters.append(continuation)
        }
    }

    func recordFirstCancelStarted() {
        firstCancelStarted = true
        firstCancelWaiters.forEach { $0.resume() }
        firstCancelWaiters.removeAll()
    }

    func waitUntilFirstCancelStarted() async {
        guard !firstCancelStarted else { return }
        await withCheckedContinuation { continuation in
            firstCancelWaiters.append(continuation)
        }
    }

    func releaseRun() {
        runReleased = true
        runReleaseWaiters.forEach { $0.resume() }
        runReleaseWaiters.removeAll()
    }

    func releaseSecondLifecycle() {
        secondLifecycleReleased = true
        secondLifecycleWaiters.forEach { $0.resume() }
        secondLifecycleWaiters.removeAll()
    }

    func waitForFirstShutdownReleaseIfNeeded(_ factoryNumber: Int) async {
        guard shouldBlockFirstShutdown, factoryNumber == 1, !firstShutdownReleased else { return }
        await withCheckedContinuation { continuation in
            firstShutdownReleaseWaiters.append(continuation)
        }
    }

    func releaseFirstShutdown() {
        firstShutdownReleased = true
        firstShutdownReleaseWaiters.forEach { $0.resume() }
        firstShutdownReleaseWaiters.removeAll()
    }

    func releaseFirstCancel() {
        firstCancelReleased = true
        firstCancelReleaseWaiters.forEach { $0.resume() }
        firstCancelReleaseWaiters.removeAll()
    }

    func releaseSecondShutdown() {
        secondShutdownReleased = true
        secondShutdownReleaseWaiters.forEach { $0.resume() }
        secondShutdownReleaseWaiters.removeAll()
    }

    func waitForShutdownReleaseIfNeeded(_ factoryNumber: Int) async {
        if factoryNumber == 1 {
            await waitForFirstShutdownReleaseIfNeeded(factoryNumber)
        } else if factoryNumber == 2, shouldBlockSecondShutdown, !secondShutdownReleased {
            await withCheckedContinuation { continuation in
                secondShutdownReleaseWaiters.append(continuation)
            }
        }
    }

    func waitForFirstCancelReleaseIfNeeded() async {
        guard shouldBlockFirstCancel, !firstCancelReleased else { return }
        await withCheckedContinuation { continuation in
            firstCancelReleaseWaiters.append(continuation)
        }
    }

    func releaseSecondFactory() {
        secondFactoryReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

@MainActor
private final class LifecycleFixtureBackend: AscendantBackend, AscendantBackendWorkspaceCapability {
    enum Outcome: Sendable, Equatable { case success, lifecycle, ordinary }

    let identity: AscendantBackendIdentity
    private var timelines: [AscendantBackendTimeline]
    private let probe: LifecycleBackendProbe
    private var outcomes: [Outcome]
    private let factoryNumber: Int
    private let throwsFromOperatedTimelines: Bool

    init(
        ascendant: NodeManifest.Ascendant,
        timelines: [NodeManifest.Timeline],
        probe: LifecycleBackendProbe,
        outcome: Outcome,
        outcomes: [Outcome] = [],
        factoryNumber: Int = 1,
        throwsFromOperatedTimelines: Bool = false
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
            .init(id: $0.id, title: $0.title, attachedWorkspaceIDs: $0.attachments.map(\.workspaceID), ascendantID: ascendant.id, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        }
        self.probe = probe
        self.outcomes = outcomes.isEmpty ? [outcome] : outcomes
        self.factoryNumber = factoryNumber
        self.throwsFromOperatedTimelines = throwsFromOperatedTimelines
    }

    func validateConfiguration() throws {}
    func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        if throwsFromOperatedTimelines { throw InjectedLifecycleFailure() }
        return timelines
    }
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        await probe.recordCreatedTimeline(id)
        await probe.beginBlockedOperation("create")
        await probe.waitForBlockedOperationRelease("create")
        let now = Date()
        let timeline = AscendantBackendTimeline(
            id: id,
            title: title,
            attachedWorkspaceIDs: [],
            ascendantID: identity.id,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )
        timelines.append(timeline)
        return timeline
    }
    func removeTimeline(id: UUID) async { timelines.removeAll { $0.id == id } }
    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        await probe.recordRename()
        await probe.beginBlockedOperation("rename")
        await probe.waitForBlockedOperationRelease("rename")
        if probe.shouldFailRename {
            throw AscendantBackendError.lifecycleUnusable(.init(code: "timelineLifecycle", message: "timeline backend failed"))
        }
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { throw NodeRuntimeError.missingTimeline(id) }
        let old = timelines[index]
        let renamed = AscendantBackendTimeline(
            id: old.id,
            title: title,
            attachedWorkspaceIDs: old.attachedWorkspaceIDs,
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
        timelines[index] = renamed
        return renamed
    }

    func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {
        await probe.recordWorkspaceAttach()
        await probe.beginBlockedOperation("attach")
        await probe.waitForBlockedOperationRelease("attach")
        if probe.shouldFailWorkspaceAttach {
            throw AscendantBackendError.lifecycleUnusable(.init(code: "workspaceLifecycle", message: "workspace backend failed"))
        }
        guard let index = timelines.firstIndex(where: { $0.id == timelineID }) else {
            throw NodeRuntimeError.missingTimeline(timelineID)
        }
        let old = timelines[index]
        let workspaceIDs = old.attachedWorkspaceIDs.contains(reference.id)
            ? old.attachedWorkspaceIDs
            : old.attachedWorkspaceIDs + [reference.id]
        timelines[index] = AscendantBackendTimeline(
            id: old.id,
            title: old.title,
            attachedWorkspaceIDs: workspaceIDs,
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }

    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        await probe.beginBlockedOperation("detach")
        await probe.waitForBlockedOperationRelease("detach")
        guard let index = timelines.firstIndex(where: { $0.id == timelineID }) else {
            throw NodeRuntimeError.missingTimeline(timelineID)
        }
        let old = timelines[index]
        timelines[index] = AscendantBackendTimeline(
            id: old.id,
            title: old.title,
            attachedWorkspaceIDs: old.attachedWorkspaceIDs.filter { $0 != workspaceID },
            ascendantID: old.ascendantID,
            isArchived: old.isArchived,
            isPrivate: old.isPrivate,
            createdAt: old.createdAt,
            updatedAt: Date()
        )
    }

    func enabledToolIDs(for _: UUID) async -> [String] { [] }

    func runTurn(_ request: AscendantBackendTurnRequest, updates _: any AscendantBackendUpdateSink) async throws -> String {
        await probe.recordRun()
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        await probe.waitForRunReleaseIfNeeded()
        await probe.waitForLifecycleReleaseIfNeeded(outcome == .lifecycle)
        switch outcome {
        case .success: return "ok: \(request.message)"
        case .lifecycle: throw AscendantBackendError.lifecycleUnusable(.init(message: "backend lifecycle failed"))
        case .ordinary: throw AscendantBackendError.terminal(.init(code: "ordinaryFailure", message: "ordinary failure"))
        }
    }

    func cancel() async {
        if factoryNumber == 1, probe.shouldBlockFirstCancel {
            await probe.recordFirstCancelStarted()
            await probe.waitForFirstCancelReleaseIfNeeded()
        }
    }

    func shutdown() async {
        await probe.recordShutdown()
        await probe.recordShutdownStarted(factoryNumber)
        await probe.waitForShutdownReleaseIfNeeded(factoryNumber)
    }
}
