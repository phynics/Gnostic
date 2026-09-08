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

    @Test("Turn IDs are canonical across provider results and replay keys")
    func canonicalIDIsSharedByTurnAndReplay() async throws {
        let store = AscendantTurnUpdateStore()
        let provider = AscendantTurnProvider(
            execute: { request in
                #expect(request.clientTurnID == "turn-1")
                return AscendantTurnResult(clientTurnID: request.clientTurnID, text: "answer")
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
        let replayResponse = try await provider.handleReplay(
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

    @Test("Canonical IDs deduplicate coordinator execution")
    func canonicalIDsShareCoordinatorResult() async throws {
        let coordinator = AscendantTurnCoordinator()
        let counter = TurnExecutionCounter()
        let first = AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: "turn-1")
        let duplicate = AscendantTurnRequest(message: "hello", timelineID: timelineID, clientTurnID: " turn-1 ")

        _ = try await coordinator.execute(first) {
            await counter.increment()
            return "answer"
        }
        let replay = try await coordinator.execute(duplicate) {
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

        let response = try await provider.handleReplay(parameters: parameters)
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
