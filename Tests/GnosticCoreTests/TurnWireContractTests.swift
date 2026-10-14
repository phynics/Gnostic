// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@Suite("Turn wire contract")
struct TurnWireContractTests {
    private let timelineID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000002")!

    @Test("Turn results round-trip text larger than the label budget")
    func resultRoundTripPreservesText() throws {
        let text = String(repeating: "x", count: 512)
        let result = AscendantTurnResult(clientTurnID: "turn-1", text: text)

        let data = try GnosticWirePayload.encode(result, context: "test result")
        let decoded = try JSONDecoder().decode(AscendantTurnResult.self, from: data)

        #expect(decoded.text == text)
        #expect(decoded.clientTurnID == "turn-1")
    }

    @Test("Turn requests round-trip a prompt larger than the label budget")
    func requestRoundTripPreservesText() throws {
        let message = String(repeating: "p", count: 512)
        let request = AscendantTurnRequest(message: message, timelineID: timelineID, clientTurnID: "turn-long")

        let data = try GnosticWirePayload.encode(request, context: "test request")
        let decoded = try JSONDecoder().decode(AscendantTurnRequest.self, from: data)

        #expect(decoded.message == message)
        #expect(decoded.clientTurnID == "turn-long")
    }

    @Test("Turn encode and decode share one prompt bound and reject instead of truncating")
    func requestRejectsOversizePrompt() throws {
        let message = String(repeating: "p", count: GnosticWirePayload.maximumTurnMessageBytes + 1)
        let request = AscendantTurnRequest(message: message, timelineID: timelineID, clientTurnID: "turn-long")

        do {
            _ = try GnosticWirePayload.encode(request, context: "test request")
            Issue.record("an oversize prompt was accepted by the encoder")
        } catch let error as GnosticWirePayload.Error {
            guard case let .tooLarge(context, actualBytes, maximumBytes) = error else {
                Issue.record("unexpected payload error: \(error)")
                return
            }
            #expect(context == "ascendant.turn message")
            #expect(actualBytes == message.utf8.count)
            #expect(maximumBytes == GnosticWirePayload.maximumTurnMessageBytes)
        }

        let payload = try JSONSerialization.data(withJSONObject: [
            "protocolMajor": GnosticProtocol.currentMajor,
            "message": message,
            "timelineID": timelineID.uuidString,
        ])
        do {
            _ = try JSONDecoder().decode(AscendantTurnRequest.self, from: payload)
            Issue.record("an oversize prompt was accepted by the decoder")
        } catch let error as GnosticWirePayload.Error {
            guard case .tooLarge = error else {
                Issue.record("unexpected payload error: \(error)")
                return
            }
        }
    }

    @Test("A prompt whose JSON encoding overflows the envelope is refused, not truncated")
    func escapeHeavyPromptIsRefused() throws {
        // 1,400 quote characters stay inside the field bound but double during
        // JSON encoding, so the request exceeds the embedded envelope.
        let message = String(repeating: "\"", count: GnosticWirePayload.maximumTurnMessageBytes)
        let request = AscendantTurnRequest(
            message: message,
            timelineID: timelineID,
            clientTurnID: String(repeating: "c", count: 128)
        )
        do {
            _ = try GnosticWirePayload.encode(request, context: "test request")
            Issue.record("an escape-heavy prompt was accepted")
        } catch let error as GnosticWirePayload.Error {
            guard case .tooLarge = error else {
                Issue.record("unexpected payload error: \(error)")
                return
            }
        }
    }

    @Test("A long prompt replay digests the same bytes as its run")
    func longPromptReplayDigestMatchesRun() async throws {
        let message = String(repeating: "p", count: 512)
        let store = AscendantTurnUpdateStore()
        let coordinator = AscendantTurnCoordinator(ledger: store)
        let provider = AscendantTurnProvider(
            execute: { request in
                try await coordinator.execute(request, ascendantID: UUID()) { request.message }
            },
            replayStore: store
        )
        let request = try JSONSerialization.data(withJSONObject: [
            "protocolMajor": GnosticProtocol.currentMajor,
            "message": message,
            "timelineID": timelineID.uuidString,
            "clientTurnID": "long-1",
        ])
        let response = try await provider.handle(operation: AscendantTurnProvider.turnOperation, parameters: String(decoding: request, as: UTF8.self))
        guard case .success = response else {
            Issue.record("the long-prompt run failed")
            return
        }

        let replayRequest = AscendantTurnReplayRequest(
            timelineID: timelineID,
            clientTurnID: "long-1",
            message: message
        )
        let replayResponse = try await provider.handle(
            operation: AscendantTurnProvider.replayOperation,
            parameters: String(decoding: try JSONEncoder().encode(replayRequest), as: UTF8.self)
        )
        guard case let .success(result: rawReplay, executionInfo: _) = replayResponse else {
            Issue.record("the long-prompt replay failed")
            return
        }
        let replay = try JSONDecoder().decode(AscendantTurnReplay.self, from: Data(rawReplay.utf8))
        #expect(!replay.conflict)
        #expect(replay.updates.last?.kind == "completion")
    }

    @Test("Turn IDs are canonical across provider results and replay keys")
    func canonicalIDIsSharedByTurnAndReplay() async throws {
        let store = AscendantTurnUpdateStore()
        let coordinator = AscendantTurnCoordinator(ledger: store)
        let provider = AscendantTurnProvider(
            execute: { request in
                #expect(request.clientTurnID == "turn-1")
                return try await coordinator.execute(request, ascendantID: UUID()) { "answer" }
            },
            replayStore: store
        )
        let request = try JSONSerialization.data(withJSONObject: [
            "protocolMajor": GnosticProtocol.currentMajor,
            "message": "hello",
            "timelineID": timelineID.uuidString,
            "clientTurnID": " turn-1 "
        ])
        let response = try await provider.handle(
            operation: AscendantTurnProvider.turnOperation,
            parameters: String(decoding: request, as: UTF8.self)
        )
        guard case let .success(result: rawResult, executionInfo: _) = response else {
            Issue.record("Turn request unexpectedly failed")
            return
        }
        let result = try JSONDecoder().decode(AscendantTurnResult.self, from: Data(rawResult.utf8))
        #expect(result.clientTurnID == "turn-1")

        let replayRequest = AscendantTurnReplayRequest(
            timelineID: timelineID, clientTurnID: "turn-1", message: "hello"
        )
        let replayResponse = try await provider.handle(
            operation: AscendantTurnProvider.replayOperation,
            parameters: String(decoding: try JSONEncoder().encode(replayRequest), as: UTF8.self)
        )
        guard case let .success(result: rawReplay, executionInfo: _) = replayResponse else {
            Issue.record("Replay request unexpectedly failed")
            return
        }
        let replay = try JSONDecoder().decode(AscendantTurnReplay.self, from: Data(rawReplay.utf8))
        #expect(replay.terminal)
        #expect(replay.updates.last?.kind == "completion")
    }

    @Test("cancellation wire request canonicalizes the ID and reports whether a Turn was active")
    func cancellationRequestIsScopedAndAcknowledged() async throws {
        let targetTimelineID = timelineID
        let provider = AscendantTurnProvider(
            execute: { _ in AscendantTurnResult(text: "unused") },
            cancel: { request in
                #expect(request.timelineID == targetTimelineID)
                #expect(request.clientTurnID == "turn-1")
                return true
            }
        )
        let parameters = try JSONSerialization.data(withJSONObject: [
            "protocolMajor": GnosticProtocol.currentMajor,
            "timelineID": targetTimelineID.uuidString,
            "clientTurnID": " turn-1 ",
        ])
        let response = try await provider.handle(
            operation: AscendantTurnProvider.cancelOperation,
            parameters: String(decoding: parameters, as: UTF8.self)
        )
        guard case let .success(result: rawResult, executionInfo: _) = response else {
            Issue.record("A valid cancellation request unexpectedly failed.")
            return
        }
        let result = try JSONDecoder().decode(AscendantTurnCancellationResult.self, from: Data(rawResult.utf8))
        #expect(result.cancelled)
    }

    @Test("Canonical IDs deduplicate coordinator execution")
    func canonicalIDsShareCoordinatorResult() async throws {
        let coordinator = AscendantTurnCoordinator()
        let counter = TurnExecutionCounter()
        let first = AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: "turn-1")
        let duplicate = AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: " turn-1 ")

        _ = try await coordinator.execute(first, ascendantID: UUID()) {
            await counter.increment()
            return "answer"
        }
        let replay = try await coordinator.execute(duplicate, ascendantID: UUID()) {
            await counter.increment()
            return "wrong"
        }

        #expect(replay.replayed)
        #expect(replay.clientTurnID == "turn-1")
        #expect(await counter.value == 1)
    }

    @Test("Replay requests preserve invalid IDs until the provider boundary")
    func replayRequestRejectsBlankIDAtProviderBoundary() async throws {
        let provider = AscendantTurnProvider(execute: { _ in AscendantTurnResult(text: "unused") }, replayStore: AscendantTurnUpdateStore())
        let request = AscendantTurnReplayRequest(timelineID: timelineID, clientTurnID: "   ")
        let parameters = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        let response = try await provider.handle(operation: AscendantTurnProvider.replayOperation, parameters: parameters)
        guard case let .failure(code, message, _) = response else {
            Issue.record("Invalid replay client ID unexpectedly succeeded")
            return
        }
        #expect(code == 400)
        #expect(message.contains("invalidClientTurnID"))
    }

    @Test("Turn provider rejects blank and oversized client IDs")
    func invalidClientIDsAreRejected() async throws {
        let provider = AscendantTurnProvider { request in
            AscendantTurnResult(clientTurnID: request.clientTurnID, text: request.message)
        }

        for clientTurnID in ["   ", String(repeating: "x", count: GnosticWirePayload.maximumIdentifierBytes + 1)] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "protocolMajor": GnosticProtocol.currentMajor,
                "message": "hello",
                "timelineID": timelineID.uuidString,
                "clientTurnID": clientTurnID
            ])
            let response = try await provider.handle(
                operation: AscendantTurnProvider.turnOperation,
                parameters: String(decoding: payload, as: UTF8.self)
            )
            guard case let .failure(code, message, _) = response else {
                Issue.record("Invalid client ID unexpectedly succeeded: \(clientTurnID)")
                continue
            }
            #expect(code == 400)
            #expect(message.contains("invalidClientTurnID"))
        }
    }
}

private actor TurnExecutionCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}
