// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import Testing

@testable import GnosticCore

/// Production-seam coverage for what a Turn commits and what a restart or a
/// concurrent retry may do with it. The tests drive the real coordinator over
/// the Turn ledger and the Timeline journal.
@Suite("Turn commit seams")
struct TurnCommitSeamTests {
    private func makeDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("a late terminal update cannot replace a committed Turn outcome, in process or after a restart")
    func lateTerminalUpdateKeepsTheCommittedOutcome() async throws {
        let directory = makeDirectory("turn-late-terminal-tests")
        let eventLog = directory.appendingPathComponent("turn-events.jsonl")
        let timelineID = UUID()
        let journals = TimelineJournalStore(directoryURL: directory.appendingPathComponent("journals"))
        let store = AscendantTurnUpdateStore(timelineJournals: journals)
        try await store.enableDurability(at: eventLog)
        let coordinator = AscendantTurnCoordinator(ledger: store)
        let request = AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: "late-terminal-1")

        let first = try await coordinator.execute(request, ascendantID: UUID()) { "answer" }
        #expect(first.text == "answer")

        // The Runtime reports a cancelled `idle` after the Turn committed.
        let clientTurnID = try await store.validatedClientTurnID("late-terminal-1")
        _ = try await store.append(
            timelineID: timelineID, clientTurnID: clientTurnID, kind: "cancellation",
            text: "late", terminal: true, reasonCode: "cancelled"
        )
        try await TimelineJournalRecorder(journals: journals).appendTurnUpdate(
            sessionID: "session-late",
            update: TimelineTurnUpdate(
                timelineID: timelineID, clientTurnID: "late-terminal-1", sequence: 99,
                update: .stateUpdate(.idle(stopReason: .cancelled, meta: nil)),
                terminal: true, terminalOutcome: .cancelled
            )
        )

        let retry = try await coordinator.execute(request, ascendantID: UUID()) {
            Issue.record("A committed Turn was dispatched again.")
            return "duplicate"
        }
        #expect(retry.text == "answer")
        #expect(retry.replayed)
        let terminals = await store.replay(timelineID: timelineID, clientTurnID: clientTurnID).updates.filter(\.terminal)
        #expect(terminals.count == 1)
        #expect(terminals.first?.kind == AscendantTurnUpdateKind.completion.rawValue)

        // A restart that recovers the event log answers the committed result.
        let restartedStore = AscendantTurnUpdateStore(timelineJournals: TimelineJournalStore(
            directoryURL: directory.appendingPathComponent("journals")
        ))
        try await restartedStore.enableDurability(at: eventLog)
        let restarted = try await AscendantTurnCoordinator(ledger: restartedStore)
            .execute(request, ascendantID: UUID()) {
                Issue.record("A restart dispatched a committed Turn.")
                return "duplicate"
            }
        #expect(restarted.text == "answer")

        // A restart that has only the Timeline journal holds the completion,
        // not the text. It reports the Turn unavailable, never cancelled.
        let journalOnly = AscendantTurnCoordinator(ledger: AscendantTurnUpdateStore(
            timelineJournals: TimelineJournalStore(directoryURL: directory.appendingPathComponent("journals"))
        ))
        do {
            _ = try await journalOnly.execute(request, ascendantID: UUID()) {
                Issue.record("A restart dispatched a committed Turn.")
                return "duplicate"
            }
            Issue.record("The journal-only restart returned a result it cannot hold.")
        } catch let error as AscendantTurnError {
            #expect(error.reasonCode == "replayUnavailable", "observed \(error.reasonCode)")
        }
    }

    @Test("concurrent replay and retry of an admitted Turn share recovery and never dispatch it")
    func concurrentReplayAndRetryShareRecovery() async throws {
        let directory = makeDirectory("turn-concurrent-recovery-tests")
        let dispatches = DispatchCount()
        let writerJournals = TimelineJournalStore(directoryURL: directory)
        let writer = AscendantTurnUpdateStore(timelineJournals: writerJournals)
        for index in 0..<16 {
            let timelineID = UUID()
            let clientTurnID = "concurrent-\(index)"
            let validated = try await writer.validatedClientTurnID(clientTurnID)
            #expect(try await writer.admit(timelineID: timelineID, clientTurnID: validated, message: "lost") == .new)

            // The restarted Node holds only the journal. A replay and several
            // retries of the admitted identity arrive together.
            let restartedStore = AscendantTurnUpdateStore(
                timelineJournals: TimelineJournalStore(directoryURL: directory)
            )
            let coordinator = AscendantTurnCoordinator(ledger: restartedStore)
            let request = AscendantTurnRequest(message: "lost", timelineID: timelineID, clientTurnID: clientTurnID)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await restartedStore.replay(timelineID: timelineID, clientTurnID: clientTurnID)
                }
                for _ in 0..<3 {
                    group.addTask {
                        do {
                            _ = try await coordinator.execute(request, ascendantID: UUID()) {
                                await dispatches.increment()
                                return "duplicate"
                            }
                            Issue.record("A retry of an admitted Turn returned a result.")
                        } catch let error as AscendantTurnError {
                            #expect(error.reasonCode == "insertionUnknown", "observed \(error.reasonCode)")
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(await dispatches.value == 0, "Recovery dispatched an admitted Turn.")
    }
}

private actor DispatchCount {
    private(set) var value = 0

    func increment() { value += 1 }
}
