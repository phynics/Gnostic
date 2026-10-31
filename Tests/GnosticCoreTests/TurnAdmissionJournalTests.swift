// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import GnosticProtocol
import Testing

/// ADR 0021 "Turn semantics": Gnostic records admission durably before it
/// dispatches the prompt, and it never dispatches an admitted Turn twice. These
/// tests drive the production coordinator and ledger over a Timeline journal.
@Suite("Turn admission journal")
struct TurnAdmissionJournalTests {
    private func makeDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func admissions(_ journals: TimelineJournalStore, _ timelineID: UUID) async throws
        -> [(clientTurnID: String, digest: String, sequence: Int, tag: String)] {
        try await journals.journal(for: timelineID).replay().compactMap { record in
            if case let .turnAdmitted(id, digest, sequence, tag, _) = record.payload {
                return (id, digest, sequence, tag)
            }
            return nil
        }
    }

    @Test("admission is journaled before the backend runs and a restart never runs it again")
    func admissionPrecedesDispatchAndSurvivesRestart() async throws {
        let directory = makeDirectory("turn-admission-restart-tests")
        let timelineID = UUID()
        let journals = TimelineJournalStore(directoryURL: directory)
        let coordinator = AscendantTurnCoordinator(ledger: AscendantTurnUpdateStore(timelineJournals: journals))
        let request = AscendantTurnRequest(message: "durable prompt", timelineID: timelineID, clientTurnID: "durable-turn")
        let sawAdmission = Flag()

        let result = try await coordinator.execute(request, ascendantID: UUID()) {
            let admitted = try await self.admissions(journals, timelineID)
            await sawAdmission.set(admitted.map(\.clientTurnID) == ["durable-turn"])
            return "answer"
        }
        #expect(result.text == "answer")
        #expect(await sawAdmission.value, "The backend ran before the admission reached the Timeline journal.")

        let admission = try #require(try await admissions(journals, timelineID).first)
        #expect(admission.tag == ACPv2Protocol.versionTag)
        #expect(admission.digest == (try TurnAdmissionDigest.hex(
            prompt: [.text(ACPTextContent(text: "durable prompt"))],
            acpVersionTag: ACPv2Protocol.versionTag
        )))

        // A restarted Node holds neither the in-flight task nor the result text.
        let restartedJournals = TimelineJournalStore(directoryURL: directory)
        let restarted = AscendantTurnCoordinator(ledger: AscendantTurnUpdateStore(timelineJournals: restartedJournals))
        let reran = Flag()
        do {
            _ = try await restarted.execute(request, ascendantID: UUID()) {
                await reran.set(true)
                return "duplicate"
            }
            Issue.record("The restarted Node answered an admitted Turn it cannot replay.")
        } catch let error as AscendantTurnError {
            #expect(error.reasonCode == "replayUnavailable")
        }
        #expect(await !reran.value, "A restart dispatched an admitted Turn a second time.")
    }

    @Test("a Turn admitted without a recorded outcome is insertionUnknown after a restart and never runs")
    func admittedTurnWithoutOutcomeIsInsertionUnknown() async throws {
        let directory = makeDirectory("turn-admission-unknown-tests")
        let timelineID = UUID()
        let writer = AscendantTurnUpdateStore(timelineJournals: TimelineJournalStore(directoryURL: directory))
        let writerID = try await writer.validatedClientTurnID("crashed-turn")
        #expect(try await writer.admit(timelineID: timelineID, clientTurnID: writerID, message: "lost") == .new)

        let restarted = AscendantTurnCoordinator(
            ledger: AscendantTurnUpdateStore(timelineJournals: TimelineJournalStore(directoryURL: directory))
        )
        let request = AscendantTurnRequest(message: "lost", timelineID: timelineID, clientTurnID: "crashed-turn")
        let reran = Flag()
        for attempt in 1...2 {
            do {
                _ = try await restarted.execute(request, ascendantID: UUID()) {
                    await reran.set(true)
                    return "duplicate"
                }
                Issue.record("Attempt \(attempt) returned a result for an unknown insertion.")
            } catch let error as AscendantTurnError {
                #expect(error.reasonCode == "insertionUnknown", "attempt \(attempt)")
                #expect(!error.retryable)
            }
        }
        #expect(await !reran.value, "An unknown insertion was dispatched again.")
    }

    @Test("a different prompt under an admitted clientTurnID is a conflict after a restart")
    func differentPromptConflictsAfterRestart() async throws {
        let directory = makeDirectory("turn-admission-conflict-tests")
        let timelineID = UUID()
        let writer = AscendantTurnUpdateStore(timelineJournals: TimelineJournalStore(directoryURL: directory))
        let writerID = try await writer.validatedClientTurnID("conflicting-turn")
        _ = try await writer.admit(timelineID: timelineID, clientTurnID: writerID, message: "first prompt")

        let reader = AscendantTurnUpdateStore(timelineJournals: TimelineJournalStore(directoryURL: directory))
        let readerID = try await reader.validatedClientTurnID("conflicting-turn")
        #expect(try await reader.admit(timelineID: timelineID, clientTurnID: readerID, message: "other prompt") == .conflict)
    }

    @Test("the Timeline journal rejects an admission whose digest is not the RFC 8785 SHA-256")
    func journalRejectsAForeignDigest() async throws {
        let directory = makeDirectory("turn-admission-foreign-digest-tests")
        let timelineID = UUID()
        let journal = try await TimelineJournalStore(directoryURL: directory).journal(for: timelineID)
        let prompt: [ACPContentBlock] = [.text(ACPTextContent(text: "hello"))]
        await #expect(throws: (any Error).self) {
            try await journal.append(.turnAdmitted(
                clientTurnID: "foreign-digest",
                admissionDigest: "0000000000000000",
                turnSequence: 1,
                acpVersionTag: ACPv2Protocol.versionTag,
                prompt: prompt
            ))
        }
    }

    @Test("the protocol major is 3, which breaks pre-0.5 contracts")
    func protocolMajorIsThree() {
        #expect(GnosticProtocol.currentMajor == 3)
        #expect(GnosticProtocol.isCompatible(3))
        #expect(!GnosticProtocol.isCompatible(2))
        #expect(!GnosticProtocol.isCompatible(1))
    }
}

private actor Flag {
    private(set) var value = false

    func set(_ newValue: Bool) { value = newValue }
}
