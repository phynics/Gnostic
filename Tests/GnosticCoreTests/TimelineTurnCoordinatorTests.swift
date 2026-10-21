// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCore
@testable import GnosticProtocol

private actor SafeCounter {
    var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor SafeFlag {
    var value = false
    func setTrue() { value = true }
    func get() -> Bool { value }
}

@Suite("Timeline-owned ACP Turn Envelope and Coordination")
struct TimelineTurnCoordinatorTests {
    private func makeEnvelope(
        timelineID: UUID = UUID(),
        clientTurnID: String = "turn-001",
        text: String = "Hello ACP",
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) -> TimelineTurnEnvelope {
        let prompt: [ACPContentBlock] = [.text(ACPTextContent(text: text))]
        let digest = TimelineTurnEnvelope.computeAdmissionDigest(prompt: prompt, acpVersionTag: "v2")
        return TimelineTurnEnvelope(
            timelineID: timelineID,
            sessionID: UUID(),
            runtimeID: UUID(),
            clientTurnID: clientTurnID,
            admissionDigest: digest,
            sequence: 1,
            acpVersionTag: "v2",
            prompt: prompt,
            state: .pendingInsertion,
            messageID: nil,
            terminalOutcome: nil,
            protocolMajor: protocolMajor
        )
    }

    @Test("Prompt blocks and admission digest are computed canonically")
    func canonicalAdmissionDigest() {
        let envelope1 = makeEnvelope(text: "Test canonical digest")
        let envelope2 = makeEnvelope(text: "Test canonical digest")
        #expect(envelope1.admissionDigest == envelope2.admissionDigest)
        #expect(!envelope1.admissionDigest.isEmpty)
    }

    @Test("Successful turn execution returns confirmed message ID and terminal outcome")
    func successfulTurnExecution() async throws {
        let coordinator = TimelineTurnCoordinator()
        let envelope = makeEnvelope()

        let result = try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
            return "msg-12345"
        })

        #expect(result.timelineID == envelope.timelineID)
        #expect(result.clientTurnID == envelope.clientTurnID)
        #expect(result.messageID == "msg-12345")
        #expect(result.terminalOutcome == .endedUnspecified)
        #expect(result.replayed == false)
        #expect(result.protocolMajor == 3)
    }

    @Test("Concurrent distinct turn on active timeline receives pre-insertion timelineBusy error (-32001)")
    func concurrentTurnReceivesTimelineBusyError() async throws {
        let coordinator = TimelineTurnCoordinator()
        let timelineID = UUID()
        let envelope1 = makeEnvelope(timelineID: timelineID, clientTurnID: "turn-1", text: "First turn")
        let envelope2 = makeEnvelope(timelineID: timelineID, clientTurnID: "turn-2", text: "Second turn")

        let dispatchStarted = AsyncStream<Void>.makeStream()

        // Launch first turn that holds the promptDispatch
        let task1 = Task {
            try await coordinator.execute(envelope: envelope1, promptDispatch: { _ in
                dispatchStarted.continuation.yield(())
                try await Task.sleep(for: .milliseconds(200))
                return "msg-turn-1"
            })
        }

        // Wait for first turn to be active
        for await _ in dispatchStarted.stream { break }

        // Second turn must fail immediately with timelineBusy (-32001) BEFORE insertion
        let promptFabricated = SafeFlag()
        do {
            _ = try await coordinator.execute(envelope: envelope2, promptDispatch: { _ in
                await promptFabricated.setTrue()
                return "msg-turn-2"
            })
            Issue.record("Expected timelineBusy error but turn succeeded")
        } catch let error as TimelineTurnError {
            #expect(error == .timelineBusy)
            #expect(error.jsonRPCErrorCode == -32001)
            #expect(error.errorDescription == "Timeline is busy")
            #expect(error.structuredData["code"] == AnySendable("timelineBusy"))
            #expect(error.structuredData["retryable"] == AnySendable(true))
        }

        let didFabricate = await promptFabricated.get()
        #expect(!didFabricate, "No prompt response may be fabricated on busy rejection")

        // Clean up task 1
        _ = try await task1.value
    }

    @Test("Identical clientTurnID retry recovers existing turn state idempotently without duplicate prompt")
    func idempotentRetryRecovery() async throws {
        let coordinator = TimelineTurnCoordinator()
        let envelope = makeEnvelope()

        let counter = SafeCounter()
        let result1 = try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
            await counter.increment()
            return "msg-idempotent-1"
        })

        let count1 = await counter.value()
        #expect(count1 == 1)
        #expect(result1.replayed == false)

        // Retry identically
        let result2 = try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
            await counter.increment()
            return "msg-idempotent-2"
        })

        let count2 = await counter.value()
        #expect(count2 == 1, "Duplicate prompt must not be initiated for identical clientTurnID retry")
        #expect(result2.replayed == true)
        #expect(result2.messageID == "msg-idempotent-1")
        #expect(result2.terminalOutcome == result1.terminalOutcome)
    }

    @Test("Conflicting payload under identical clientTurnID is rejected")
    func conflictingPayloadUnderIdenticalClientTurnID() async throws {
        let coordinator = TimelineTurnCoordinator()
        let timelineID = UUID()
        let envelope1 = makeEnvelope(timelineID: timelineID, clientTurnID: "turn-shared", text: "Original message")

        _ = try await coordinator.execute(envelope: envelope1, promptDispatch: { _ in "msg-1" })

        // Different message under identical clientTurnID
        let envelope2 = makeEnvelope(timelineID: timelineID, clientTurnID: "turn-shared", text: "Conflicting message")

        do {
            _ = try await coordinator.execute(envelope: envelope2, promptDispatch: { _ in "msg-2" })
            Issue.record("Expected conflicting payload error")
        } catch let error as TimelineTurnError {
            if case let .conflictingPayload(id) = error {
                #expect(id == "turn-shared")
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Lost prompt response enters insertionUnknown without unsafe retries")
    func lostPromptResponseEntersInsertionUnknown() async throws {
        let coordinator = TimelineTurnCoordinator()
        let envelope = makeEnvelope()

        do {
            _ = try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
                throw TimelineTurnError.insertionUnknown
            })
            Issue.record("Expected insertionUnknown error")
        } catch let error as TimelineTurnError {
            #expect(error == .insertionUnknown)
            #expect(error.jsonRPCErrorCode == -32000)
        }

        // Subsequent retry of the turn should see recorded insertionUnknown outcome
        let retryResult = try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
            Issue.record("Unsafe retry dispatched")
            return "msg-retry"
        })

        #expect(retryResult.replayed == true)
        #expect(retryResult.terminalOutcome == .insertionUnknown)
    }

    @Test("Unanswered permission request returns -32800 and records decision as unavailable; replay preserves decision")
    func permissionTimeoutMediation() async throws {
        let coordinator = TimelineTurnCoordinator()
        let timelineID = UUID()
        let correlationID = "perm-correl-\(UUID().uuidString)"
        let request = TimelinePermissionRequest(
            correlationID: correlationID,
            timelineID: timelineID,
            clientTurnID: "turn-p1",
            title: "Run command",
            subject: "executeCommand",
            options: [],
            protocolMajor: GnosticProtocol.currentMajor
        )

        // Time out with short timeout duration
        do {
            _ = try await coordinator.mediatePermission(request: request, timeout: .milliseconds(50)) { _ in
                try await Task.sleep(for: .milliseconds(500))
                return TimelinePermissionResponse(
                    correlationID: correlationID,
                    timelineID: timelineID,
                    clientTurnID: "turn-p1",
                    approved: true,
                    protocolMajor: GnosticProtocol.currentMajor
                )
            }
            Issue.record("Expected timeout cancellation error")
        } catch let error as ACPError {
            #expect(error.errorCode == -32800)
        }

        // Replay of the timed-out permission request returns recorded decision as unavailable and NEVER prompts again
        let promptedAgain = SafeFlag()
        let replayResponse = try await coordinator.mediatePermission(request: request, timeout: .seconds(5)) { _ in
            await promptedAgain.setTrue()
            return TimelinePermissionResponse(
                correlationID: correlationID,
                timelineID: timelineID,
                clientTurnID: "turn-p1",
                approved: true,
                protocolMajor: GnosticProtocol.currentMajor
            )
        }

        let didPrompt = await promptedAgain.get()
        #expect(!didPrompt, "Replay must never prompt again for recorded permission decision")
        #expect(replayResponse.approved == false)
        #expect(replayResponse.decision == "unavailable")
    }

    @Test("Single protocolMajor bump is 3, breaking pre-0.5 contracts")
    func protocolMajorIsThree() {
        #expect(GnosticProtocol.currentMajor == 3)
        #expect(GnosticProtocol.isCompatible(3))
        #expect(!GnosticProtocol.isCompatible(2))
        #expect(!GnosticProtocol.isCompatible(1))
    }

    @Test("Fitness test: No Gnostic-owned wire type, method, or manifest key is named Ascendant")
    func architectureFitnessTestNoAscendantOnWireOrManifest() throws {
        // 1. Wire object type check
        let runtimeInstanceType = GnosticObjectType.runtimeInstance
        #expect(!runtimeInstanceType.contains("Ascendant"), "RuntimeInstance wire type must not contain 'Ascendant': \(runtimeInstanceType)")
        #expect(runtimeInstanceType == "me.atkn.gnostic.RuntimeInstance")

        // 2. Wire operations check
        let operations = [
            TimelineTurnProvider.turnOperation,
            TimelineTurnProvider.cancelOperation,
            TimelineTurnProvider.replayOperation,
            TimelineTurnProvider.updateChannel,
            TimelinePermissionProvider.permissionOperation,
            TimelinePermissionProvider.responseOperation,
            TimelinePermissionProvider.responseChannel,
        ]
        for op in operations {
            #expect(!op.contains("ascendant"), "Wire operation '\(op)' must not contain 'ascendant'")
            #expect(op.contains("timeline"), "Wire operation '\(op)' must be timeline-owned")
        }

        // 3. Manifest keys check
        let manifest = NodeManifest.makeDefault(broker: .init(host: "localhost", port: 1883, namespace: "test"))
        let data = try JSONEncoder().encode(manifest)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(jsonObject != nil)

        // Verify root manifest keys
        #expect(jsonObject?["ascendants"] == nil, "Root manifest JSON must not contain key 'ascendants'")
        #expect(jsonObject?["runtimeInstances"] != nil, "Root manifest JSON must contain key 'runtimeInstances'")

        // Verify timeline keys
        if let timelines = jsonObject?["timelines"] as? [[String: Any]], let firstTimeline = timelines.first {
            #expect(firstTimeline["operatingAscendantID"] == nil, "Timeline JSON must not contain key 'operatingAscendantID'")
            #expect(firstTimeline["runtimeInstanceID"] != nil, "Timeline JSON must contain key 'runtimeInstanceID'")
        } else {
            Issue.record("timelines array missing in encoded manifest")
        }
    }
}
