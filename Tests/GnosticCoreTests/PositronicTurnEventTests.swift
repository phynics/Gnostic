// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import PKContracts
import PositronicKit
import Testing

@Suite("Positronic backend terminal Turn events")
struct PositronicTurnEventTests {
    @Test("a durability failure terminal event fails the Turn instead of succeeding empty")
    func durabilityFailureFailsTheTurn() async throws {
        let stream = makeStream([
            .error(.durabilityFailure(message: "The terminal outcome could not be persisted.", identity: nil)),
        ])

        let failure = try await consume(stream)

        #expect(failure.code == "turnFailed")
        #expect(failure.message == "The terminal outcome could not be persisted.")
    }

    @Test("a tool-call failure terminal event fails the Turn")
    func toolCallErrorFailsTheTurn() async throws {
        let stream = makeStream([
            .error(.toolCallError(toolCallID: "call-1", name: "notes", error: "notes tool is unavailable")),
        ])

        let failure = try await consume(stream)

        #expect(failure.code == "turnFailed")
        #expect(failure.message == "notes tool is unavailable")
    }

    @Test("an empty completion remains a successful empty reply")
    func emptyCompletionStaysSuccessful() async throws {
        let stream = makeStream([
            .completion(.completedEmpty(finishReason: nil)),
        ])

        let reply = try await PositronicAscendantAdapter.consumeTurnEvents(
            stream,
            clientTurnID: "turn-empty",
            timelineID: UUID(),
            updates: NoopUpdateSink()
        )

        #expect(reply == "(empty reply)")
    }

    private func consume(_ stream: AsyncStream<TurnEvent>) async throws -> AscendantBackendTerminalFailure {
        do {
            _ = try await PositronicAscendantAdapter.consumeTurnEvents(
                stream,
                clientTurnID: "turn-1",
                timelineID: UUID(),
                updates: NoopUpdateSink()
            )
            Issue.record("expected the Turn to fail, but it succeeded")
            throw UnexpectedSuccess()
        } catch let error as AscendantBackendError {
            guard case let .terminal(failure) = error else {
                Issue.record("expected a terminal backend failure, got \(error)")
                throw UnexpectedSuccess()
            }
            return failure
        }
    }

    private func makeStream(_ events: [TurnEvent]) -> AsyncStream<TurnEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private struct UnexpectedSuccess: Error {}

    private struct NoopUpdateSink: AscendantBackendUpdateSink {
        func append(_: AscendantBackendUpdate) async throws {}
    }
}
