// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import Testing

@testable import GnosticCLI

@Suite("ACP JSON-RPC protocol")
struct JSONRPCProtocolTests {
    @Test("LF framing splits only on byte newline and preserves Unicode separators")
    func lfFramingPreservesUnicodeSeparators() throws {
        var framer = LFMessageFramer()
        let message = #"{"jsonrpc":"2.0","id":"1","method":"echo","params":{"text":"line paragraph "}}"#
        let bytes = Data((message + "\n").utf8)

        #expect(framer.append(Data(bytes.prefix(7))).isEmpty)
        let frames = framer.append(Data(bytes.dropFirst(7)))

        #expect(frames.count == 1)
        #expect(String(decoding: frames[0], as: UTF8.self) == message)
    }

    @Test("partial frames are retained until the next LF byte")
    func partialFramesAreRetained() {
        var framer = LFMessageFramer()

        #expect(framer.append(Data(#"{"jsonrpc":"2.0"}"#.utf8)).isEmpty)
        #expect(framer.append(Data([0x0A])).count == 1)
        #expect(String(decoding: framer.append(Data([0x0A]))[0], as: UTF8.self).isEmpty)
    }

    @Test("JSON-RPC request and error response round-trip")
    func requestAndErrorResponseRoundTrip() throws {
        let request = JSONRPCRequest(
            id: .string("42"),
            method: "session/list",
            params: .dictionary(["includeArchived": .boolean(false)])
        )
        let encodedRequest = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: encodedRequest)
        #expect(decodedRequest == request)

        let response = JSONRPCResponse(
            id: .string("42"),
            error: JSONRPCErrorObject(
                code: JSONRPCErrorCode.invalidParams.rawValue,
                message: "Invalid params",
                data: .dictionary(["gnosticCode": .string("workspaceNotFound")])
            )
        )
        let decodedResponse = try JSONDecoder().decode(JSONRPCResponse.self, from: JSONEncoder().encode(response))
        #expect(decodedResponse == response)
    }

    @Test("responses for parse failures carry a JSON null id")
    func nilResponseIDIsExplicit() throws {
        let response = JSONRPCResponse(
            id: nil,
            error: JSONRPCErrorObject(code: JSONRPCErrorCode.parseError.rawValue, message: "Invalid JSON")
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(object["id"] is NSNull)
    }

    @Test("request rejects a non-2.0 protocol version")
    func requestRejectsWrongVersion() {
        let data = Data(#"{"jsonrpc":"1.0","id":1,"method":"noop"}"#.utf8)
        #expect(throws: JSONRPCProtocolError.invalidRequest) {
            _ = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        }
    }
}
