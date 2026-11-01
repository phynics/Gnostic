// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPFrontend
import GnosticClient
import GnosticProtocol
import Testing

/// ADR 0021 "Timeline journal": a Timeline whose committed journal is corrupt is
/// quarantined read-only. A Turn on it fails with a distinct, non-retryable
/// `timelineQuarantined` code, and `gnostic acp` hands that code to the client.
@Suite("gnostic acp quarantined Timeline", .serialized)
struct ACPQuarantinedTimelineTests {
    @Test("a Node's timelineQuarantined rejection reaches an ACP client as a structured, non-retryable error")
    func clientSeesTimelineQuarantined() async throws {
        let wire = ACPWireCapture()
        let session = JSONRPCSession(
            handler: { _ in
                // The error the Turn client throws for the Node's wire rejection.
                throw await RemoteTurnClient.remoteError(
                    GnosticTurnClientError.callFailed(reasonCode: "timelineQuarantined", statusCode: 423, retryable: false)
                )
            },
            output: { data in wire.record(frame: data) }
        )
        await session.receive(Data(
            (#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}"# + "\n").utf8
        ))
        _ = await wire.response(id: 1, timeout: .seconds(5))
        await session.receive(Data(
            (#"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s","prompt":[]}}"# + "\n").utf8
        ))

        let response = try #require(await wire.response(id: 2, timeout: .seconds(5)))
        let error = try #require(response.error, "The prompt on a quarantined Timeline succeeded.")
        #expect(error.code == JSONRPCErrorCode.invalidState.rawValue)
        #expect(error.data == .dictionary(["gnosticCode": .string("timelineQuarantined")]))
        #expect(error.message == RemoteTurnClientError.timelineQuarantined.errorDescription)
        #expect(!error.message.contains("/"), "The error message names a path.")
    }
}
