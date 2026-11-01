// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPFrontend
import GnosticProtocol
import Testing

/// ADR 0019 T1: `gnostic acp` refuses an ACP v1 client at `initialize`, before
/// it resolves a Runtime or opens a Session. These cases drive the
/// `JSONRPCSession` that `ACPServer` runs over stdio.
@Suite("gnostic acp protocol version", .serialized)
struct ACPInitializeVersionTests {
    private final class Probe: @unchecked Sendable { // SAFETY: `lock` guards `count`.
        private let lock = NSLock()
        private var count = 0

        var initializations: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func record() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
    }

    private func session(_ probe: Probe, _ wire: ACPWireCapture) -> JSONRPCSession {
        JSONRPCSession(
            handler: { _ in .dictionary([:]) },
            output: { data in wire.record(frame: data) },
            initialize: {
                probe.record()
                return .dictionary(["protocolVersion": .integer(Int64(ACPProtocol.version))])
            }
        )
    }

    private func initialize(_ session: JSONRPCSession, id: Int, protocolVersion: String) async {
        await session.receive(Data(
            #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":\#(protocolVersion)}}"#.utf8 + [0x0A]
        ))
    }

    @Test("an ACP v1 initialize is rejected with the version error and never reaches the Node", arguments: ["1", "0", "\"1\""])
    func rejectsV1(protocolVersion: String) async throws {
        let probe = Probe()
        let wire = ACPWireCapture()
        let session = session(probe, wire)

        await initialize(session, id: 1, protocolVersion: protocolVersion)

        let response = try #require(await wire.response(id: 1, timeout: .seconds(5)))
        #expect(response.result == nil)
        #expect(response.error?.code == ACPv2Protocol.ErrorCode.unsupportedProtocolVersion)
        #expect(response.error?.message.contains("ACP v1 is not supported") == true)
        #expect(probe.initializations == 0, "A v1 client reached Runtime resolution.")
        #expect(await session.currentState() == .awaitingInitialize)
    }

    @Test("a v1 initialize leaves the session open for a v2 initialize")
    func v2FollowsARejectedV1() async throws {
        let probe = Probe()
        let wire = ACPWireCapture()
        let session = session(probe, wire)

        await initialize(session, id: 1, protocolVersion: "1")
        await initialize(session, id: 2, protocolVersion: "2")

        let accepted = try #require(await wire.response(id: 2, timeout: .seconds(5)))
        #expect(accepted.error == nil)
        #expect(probe.initializations == 1)
        #expect(await session.currentState() == .initialized)
    }

    @Test("a v1 client cannot prompt without a successful initialize")
    func v1ClientCannotPrompt() async throws {
        let probe = Probe()
        let wire = ACPWireCapture()
        let session = session(probe, wire)

        await initialize(session, id: 1, protocolVersion: "1")
        await session.receive(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"s","prompt":[]}}"#.utf8 + [0x0A]
        ))

        let response = try #require(await wire.response(id: 2, timeout: .seconds(5)))
        #expect(response.result == nil)
        #expect(response.error != nil)
    }

    @Test("the frontend answers a v2 initialize with protocol version 2")
    func advertisesV2() {
        #expect(ACPProtocol.version == ACPv2Protocol.protocolVersion)
    }
}
