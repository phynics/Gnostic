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

    private func makeCoordinator() -> TimelineTurnCoordinator {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-turn-coordinator-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return TimelineTurnCoordinator(journals: TimelineJournalStore(directoryURL: directory))
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
        let coordinator = makeCoordinator()
        let envelope = makeEnvelope()

        let result = try await coordinator.execute(envelope: envelope, promptDispatch: { envelope in
            try await coordinator.recordTerminalUpdate(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                stopReason: .endTurn
            )
            return "msg-12345"
        })

        #expect(result.timelineID == envelope.timelineID)
        #expect(result.clientTurnID == envelope.clientTurnID)
        #expect(result.messageID == "msg-12345")
        #expect(result.terminalOutcome == .completed)
        #expect(result.replayed == false)
        #expect(result.protocolMajor == 3)
    }

    @Test("A turn stays active until the session emits its terminal update")
    func turnStaysActiveUntilTerminalUpdate() async throws {
        let coordinator = makeCoordinator()
        let envelope = makeEnvelope(clientTurnID: "turn-active")
        let inserted = AsyncStream<Void>.makeStream()

        let execution = Task {
            try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
                inserted.continuation.yield(())
                return "msg-active"
            })
        }

        for await _ in inserted.stream { break }
        // The prompt response is only the insertion handshake, so the Turn is
        // still active and a second Turn is rejected as busy.
        do {
            _ = try await coordinator.execute(
                envelope: makeEnvelope(timelineID: envelope.timelineID, clientTurnID: "turn-second"),
                promptDispatch: { _ in "msg-second" }
            )
            Issue.record("Expected timelineBusy error while the first turn is active")
        } catch let error as TimelineTurnError {
            #expect(error == .timelineBusy)
        }

        try await coordinator.recordTerminalUpdate(
            timelineID: envelope.timelineID,
            clientTurnID: envelope.clientTurnID,
            stopReason: .endTurn
        )
        let result = try await execution.value
        #expect(result.terminalOutcome == .completed)
        #expect(result.messageID == "msg-active")
    }

    @Test("Concurrent distinct turn on active timeline receives pre-insertion timelineBusy error (-32001)")
    func concurrentTurnReceivesTimelineBusyError() async throws {
        let coordinator = makeCoordinator()
        let timelineID = UUID()
        let envelope1 = makeEnvelope(timelineID: timelineID, clientTurnID: "turn-1", text: "First turn")
        let envelope2 = makeEnvelope(timelineID: timelineID, clientTurnID: "turn-2", text: "Second turn")

        let dispatchStarted = AsyncStream<Void>.makeStream()

        // Launch first turn that holds the promptDispatch
        let task1 = Task {
            try await coordinator.execute(envelope: envelope1, promptDispatch: { envelope in
                dispatchStarted.continuation.yield(())
                try await Task.sleep(for: .milliseconds(200))
                try await coordinator.recordTerminalUpdate(
                    timelineID: envelope.timelineID,
                    clientTurnID: envelope.clientTurnID,
                    stopReason: .endTurn
                )
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
        let coordinator = makeCoordinator()
        let envelope = makeEnvelope()

        let counter = SafeCounter()
        let result1 = try await coordinator.execute(envelope: envelope, promptDispatch: { envelope in
            await counter.increment()
            try await coordinator.recordTerminalUpdate(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                stopReason: .endTurn
            )
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

    @Test("admission is durable before prompt dispatch and a restart never dispatches it twice")
    func durableAdmissionPrecedesPromptAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-turn-admission-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let timelineID = UUID()
        let envelope = makeEnvelope(timelineID: timelineID, clientTurnID: "durable-turn")
        let store = TimelineJournalStore(directoryURL: directory)
        let journal = try await store.journal(for: timelineID)
        let coordinator = TimelineTurnCoordinator(journals: store)
        let dispatchSawAdmission = SafeFlag()

        _ = try await coordinator.execute(envelope: envelope, promptDispatch: { envelope in
            let records = try await journal.replay()
            let admitted = records.contains { record in
                if case let .turnAdmitted(clientTurnID, digest, _, _, prompt) = record.payload {
                    return clientTurnID == envelope.clientTurnID
                        && digest == envelope.admissionDigest
                        && prompt == envelope.prompt
                }
                return false
            }
            await dispatchSawAdmission.setTrue()
            #expect(admitted)
            try await coordinator.recordTerminalUpdate(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                stopReason: .endTurn
            )
            return "message-durable"
        })
        #expect(await dispatchSawAdmission.get())

        let restarted = TimelineTurnCoordinator(journals: TimelineJournalStore(directoryURL: directory))
        let duplicateDispatch = SafeFlag()
        let replayed = try await restarted.execute(envelope: envelope, promptDispatch: { _ in
            await duplicateDispatch.setTrue()
            return "duplicate-message"
        })
        #expect(replayed.replayed)
        #expect(replayed.messageID == "message-durable")
        #expect(replayed.terminalOutcome == .completed)
        #expect(!(await duplicateDispatch.get()))
    }

    @Test("concurrent replay and retry share recovery without another dispatch")
    func concurrentReplayAndRetryShareRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelineJournalStore(directoryURL: directory)
        let coordinator = TimelineTurnCoordinator(journals: store)
        for _ in 0..<32 {
            let envelope = makeEnvelope()
            let journal = try await store.journal(for: envelope.timelineID)
            try await journal.append(.turnAdmitted(
                clientTurnID: envelope.clientTurnID, admissionDigest: envelope.admissionDigest,
                turnSequence: envelope.sequence, acpVersionTag: envelope.acpVersionTag, prompt: envelope.prompt
            ))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await coordinator.replay(timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID)
                }
                group.addTask {
                    let result = try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
                        Issue.record("Recovery dispatched an already admitted Turn")
                        try await coordinator.recordTerminalUpdate(
                            timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID, stopReason: .endTurn
                        )
                        return "duplicate"
                    })
                    #expect(result.replayed)
                    #expect(result.terminalOutcome == .insertionUnknown)
                }
                try await group.waitForAll()
            }
        }
    }

    @Test("idle without a committed prompt acknowledgement remains insertionUnknown after restart")
    func idleWithoutAcknowledgementRemainsUnknown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelineJournalStore(directoryURL: directory)
        let envelope = makeEnvelope()
        let journal = try await store.journal(for: envelope.timelineID)
        try await journal.append(.turnAdmitted(
            clientTurnID: envelope.clientTurnID, admissionDigest: envelope.admissionDigest,
            turnSequence: envelope.sequence, acpVersionTag: envelope.acpVersionTag, prompt: envelope.prompt
        ))
        try await journal.append(.acpUpdate(sessionID: "session", update: TimelineTurnUpdate(
            timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID, sequence: 1,
            update: .stateUpdate(.idle(stopReason: .endTurn, meta: nil)), terminal: true, terminalOutcome: .completed
        )))
        let restarted = TimelineTurnCoordinator(journals: store)
        let result = try await restarted.execute(envelope: envelope, promptDispatch: { _ in
            Issue.record("An uncertain admission was dispatched again")
            return "duplicate"
        })
        #expect(result.replayed)
        #expect(result.messageID == nil)
        #expect(result.terminalOutcome == .insertionUnknown)
    }

    @Test("late terminal updates cannot replace committed completion on restart")
    func lateTerminalPreservesCommittedOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelineJournalStore(directoryURL: directory)
        let coordinator = TimelineTurnCoordinator(journals: store)
        let envelope = makeEnvelope()
        _ = try await coordinator.execute(envelope: envelope, promptDispatch: { envelope in
            try await coordinator.recordTerminalUpdate(
                timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID, stopReason: .endTurn
            )
            return "committed-message"
        })
        try await coordinator.recordUpdate(TimelineTurnUpdate(
            timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID, sequence: 2,
            update: .stateUpdate(.idle(stopReason: .cancelled, meta: nil)),
            terminal: true, terminalOutcome: .cancelled
        ))
        let restarted = TimelineTurnCoordinator(journals: store)
        let replay = try await restarted.replay(timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID)
        #expect(replay?.terminalOutcome == .completed)
        let result = try await restarted.execute(envelope: envelope, promptDispatch: { _ in
            Issue.record("A completed Turn was dispatched again")
            return "duplicate"
        })
        #expect(result.messageID == "committed-message")
        #expect(result.terminalOutcome == .completed)
        #expect(replay?.updates.count == 1)
    }

    @Test("an ACP update is durable before the stream handler forwards it")
    func acpUpdateIsDurableBeforeForwarding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-turn-update-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let timelineID = UUID()
        let store = TimelineJournalStore(directoryURL: directory)
        let journal = try await store.journal(for: timelineID)
        let coordinator = TimelineTurnCoordinator(journals: store)
        let envelope = makeEnvelope(timelineID: timelineID, clientTurnID: "raw-update")
        let observedDurableUpdate = SafeFlag()
        let update = TimelineTurnUpdate(
            timelineID: timelineID,
            clientTurnID: envelope.clientTurnID,
            sequence: 1,
            update: .other(
                sessionUpdate: "future_update",
                fields: ["_meta": .object(["source": .string("runtime")])]
            ),
            terminal: true,
            terminalOutcome: .completed
        )

        _ = try await coordinator.execute(
            envelope: envelope,
            promptDispatch: { _ in
                try await coordinator.recordUpdate(update, sessionID: "session-raw")
                return "message-raw"
            },
            streamUpdates: { forwarded in
                let records = try? await journal.replay()
                let durable = records?.contains { record in
                    record.payload == .acpUpdate(sessionID: "session-raw", update: forwarded)
                } == true
                if durable { await observedDurableUpdate.setTrue() }
            }
        )
        #expect(await observedDurableUpdate.get())

        let records = try await journal.replay()
        #expect(records.contains { $0.payload == .acpUpdate(sessionID: "session-raw", update: update) })

        let restarted = TimelineTurnCoordinator(journals: TimelineJournalStore(directoryURL: directory))
        let duplicateDispatch = SafeFlag()
        let replayed = try await restarted.execute(envelope: envelope, promptDispatch: { _ in
            await duplicateDispatch.setTrue()
            return "must-not-dispatch"
        })
        #expect(replayed.replayed)
        #expect(replayed.terminalOutcome == .completed)
        #expect(!(await duplicateDispatch.get()))
        let replay = try await restarted.replay(timelineID: timelineID, clientTurnID: envelope.clientTurnID)
        #expect(replay?.updates == [update])
    }

    @Test("Conflicting payload under identical clientTurnID is rejected")
    func conflictingPayloadUnderIdenticalClientTurnID() async throws {
        let coordinator = makeCoordinator()
        let timelineID = UUID()
        let envelope1 = makeEnvelope(timelineID: timelineID, clientTurnID: "turn-shared", text: "Original message")

        _ = try await coordinator.execute(envelope: envelope1, promptDispatch: { envelope in
            try await coordinator.recordTerminalUpdate(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                stopReason: .endTurn
            )
            return "msg-1"
        })

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
        let coordinator = makeCoordinator()
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
        let coordinator = makeCoordinator()
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

    @Test("Cancelling an active turn records cancelled and rejects the in-flight caller")
    func cancellationRecordsCancelledOutcome() async throws {
        let coordinator = makeCoordinator()
        let envelope = makeEnvelope(clientTurnID: "turn-cancel")
        let started = AsyncStream<Void>.makeStream()

        let task = Task {
            try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
                return "msg-never"
            })
        }

        for await _ in started.stream { break }
        #expect(try await coordinator.cancel(timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID))

        do {
            _ = try await task.value
            Issue.record("Expected turnCancelled error")
        } catch let error as TimelineTurnError {
            #expect(error == .turnCancelled)
            #expect(error.jsonRPCErrorCode == -32800)
        }

        let replay = try await coordinator.replay(timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID)
        #expect(replay?.terminalOutcome == .cancelled)

        let retry = try await coordinator.execute(envelope: envelope, promptDispatch: { _ in
            Issue.record("Cancelled turn must not dispatch again")
            return "msg-retry"
        })
        #expect(retry.replayed)
        #expect(retry.terminalOutcome == .cancelled)
    }

    @Test("A terminal session update owns the returned terminal outcome")
    func terminalUpdateOwnsOutcome() async throws {
        let coordinator = makeCoordinator()
        let envelope = makeEnvelope(clientTurnID: "turn-terminal")

        let result = try await coordinator.execute(envelope: envelope, promptDispatch: { envelope in
            try await coordinator.recordTerminalUpdate(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                stopReason: .endTurn
            )
            return "msg-terminal"
        })

        #expect(result.terminalOutcome == .completed)
        #expect(result.messageID == "msg-terminal")
    }

    @Test("Streamed updates are forwarded once and preserved for replay")
    func streamedUpdatesArePreserved() async throws {
        let coordinator = makeCoordinator()
        let envelope = makeEnvelope(clientTurnID: "turn-stream")
        let received = SafeCounter()
        let update = TimelineTurnUpdate(
            timelineID: envelope.timelineID,
            clientTurnID: envelope.clientTurnID,
            sequence: 1,
            update: .stateUpdate(.idle(stopReason: .endTurn, meta: nil)),
            terminal: true,
            terminalOutcome: .completed
        )

        let result = try await coordinator.execute(
            envelope: envelope,
            promptDispatch: { _ in
                try await coordinator.recordUpdate(update)
                return "msg-stream"
            },
            streamUpdates: { _ in await received.increment() }
        )

        #expect(await received.value() == 1)
        #expect(result.terminalOutcome == .completed)
        let replay = try await coordinator.replay(timelineID: envelope.timelineID, clientTurnID: envelope.clientTurnID)
        #expect(replay?.updates == [update])
    }

    @Test("Provider returns the message ID confirmed by the runtime dispatcher")
    func providerUsesRuntimeDispatcher() async throws {
        let coordinator = makeCoordinator()
        let provider = TimelineTurnProvider(coordinator: coordinator, promptDispatcher: { envelope in
            #expect(envelope.state == .pendingInsertion)
            try await coordinator.recordTerminalUpdate(
                timelineID: envelope.timelineID,
                clientTurnID: envelope.clientTurnID,
                stopReason: .endTurn
            )
            return "msg-confirmed"
        })
        let envelope = makeEnvelope(clientTurnID: "turn-provider")
        let parameters = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)

        let outcome = try await provider.handle(
            operation: TimelineTurnProvider.turnOperation,
            parameters: parameters
        )
        guard case let .success(result, _) = outcome else {
            Issue.record("Expected a successful timeline.turn result")
            return
        }
        let decoded = try JSONDecoder().decode(TimelineTurnResult.self, from: Data(result.utf8))
        #expect(decoded.messageID == "msg-confirmed")
        #expect(decoded.terminalOutcome == .completed)
    }

    @Test("Provider publishes streamed turn updates to the update channel publisher")
    func providerPublishesStreamedUpdates() async throws {
        let coordinator = makeCoordinator()
        let update = TimelineTurnUpdate(
            timelineID: UUID(),
            clientTurnID: "turn-publish",
            sequence: 1,
            update: .stateUpdate(.idle(stopReason: .endTurn, meta: nil)),
            terminal: true,
            terminalOutcome: .completed
        )
        let provider = TimelineTurnProvider(coordinator: coordinator, promptDispatcher: { envelope in
                try await coordinator.recordUpdate(
                TimelineTurnUpdate(
                    timelineID: envelope.timelineID,
                    clientTurnID: envelope.clientTurnID,
                    sequence: 1,
                    update: .stateUpdate(.idle(stopReason: .endTurn, meta: nil)),
                    terminal: true,
                    terminalOutcome: .completed
                )
            )
            return "msg-published"
        })
        let envelope = makeEnvelope(timelineID: update.timelineID, clientTurnID: update.clientTurnID)
        let parameters = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        let received = SafeCounter()

        let outcome = try await provider.handle(
            operation: TimelineTurnProvider.turnOperation,
            parameters: parameters,
            publishUpdate: { _ in await received.increment() }
        )
        guard case .success = outcome else {
            Issue.record("Expected a successful timeline.turn result")
            return
        }
        #expect(await received.value() == 1)
    }

    @Test("Structured busy error data keeps retryable as a JSON boolean")
    func structuredDataKeepsBooleanType() throws {
        let data = try JSONEncoder().encode(TimelineTurnError.timelineBusy.structuredData)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["code"] as? String == "timelineBusy")
        #expect(object["retryable"] as? Bool == true)
    }
}
