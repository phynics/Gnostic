// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticProtocol

@Suite("ACP v2 wire model (GNO-ARCH-015)")
struct ACPv2WireModelTests {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    @Test("protocol baseline constants match ADR 0019 pinned revision")
    func protocolBaselineConstants() {
        #expect(ACPv2Protocol.pinnedSchemaRevision == "39ae6a2")
        #expect(ACPv2Protocol.protocolVersion == 2)
        #expect(ACPv2Protocol.versionTag == "acp-v2@39ae6a2")
        #expect(ACPv2Protocol.isOptInPreview == true)
        #expect(ACPv2Protocol.ErrorCode.requestCancelled == -32800)
        #expect(ACPv2Protocol.ErrorCode.timelineBusy == -32001)
        #expect(ACPv2Protocol.ErrorCode.protocolVersionMismatch == -32000)
    }

    @Test("strict ACP v1 rejection throws protocolVersionMismatch")
    func strictV1Rejection() {
        #expect(throws: ACPError.self) {
            try ACPv2Protocol.validateProtocolVersion(1)
        }
        #expect(throws: ACPError.self) {
            try ACPv2Protocol.validateProtocolVersion(0)
        }
        #expect(throws: Never.self) {
            try ACPv2Protocol.validateProtocolVersion(2)
        }
        #expect(throws: Never.self) {
            try ACPv2Protocol.validateProtocolVersion(3)
        }
    }

    @Test("busy error carries standard code -32001 and retryable payload")
    func busyErrorStructure() {
        let busy = ACPError.timelineBusy()
        let rpc = busy.toJSONRPCError()
        #expect(rpc.code == -32001)
        #expect(rpc.message == "Timeline is busy")
        #expect(rpc.data?["code"] == .string("timelineBusy"))
        #expect(rpc.data?["retryable"] == .boolean(true))
    }

    @Test("executing-party request cancellation maps to error -32800")
    func permissionCancellationErrorCode() {
        let cancelled = ACPError.requestCancelled("Request cancelled")
        let rpc = cancelled.toJSONRPCError()
        #expect(rpc.code == -32800)
    }

    @Test("lossless round-trip of unknown session update variants")
    func unknownSessionUpdateRoundTrip() throws {
        let json = """
        {
          "_meta": {
            "customTrace": "trace-987"
          },
          "customField": 42,
          "sessionUpdate": "custom_extension_event"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try decoder.decode(ACPSessionUpdate.self, from: data)

        guard case let .other(kind, fields) = decoded else {
            Issue.record("Expected .other session update, got \(decoded)")
            return
        }
        #expect(kind == "custom_extension_event")
        #expect(fields["customField"] == .int(42))
        #expect(fields["_meta"] == .object(["customTrace": .string("trace-987")]))

        let encodedData = try encoder.encode(decoded)
        let roundTripped = try decoder.decode(ACPSessionUpdate.self, from: encodedData)
        #expect(roundTripped == decoded)
    }

    @Test("lossless round-trip of unknown content block variants")
    func unknownContentBlockRoundTrip() throws {
        let json = """
        {
          "_meta": {
            "vendor": "gnostic"
          },
          "payload": "custom-payload-data",
          "type": "future_content_block"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try decoder.decode(ACPContentBlock.self, from: data)

        guard case let .other(type, fields) = decoded else {
            Issue.record("Expected .other content block, got \(decoded)")
            return
        }
        #expect(type == "future_content_block")
        #expect(fields["payload"] == .string("custom-payload-data"))

        let encodedData = try encoder.encode(decoded)
        let roundTripped = try decoder.decode(ACPContentBlock.self, from: encodedData)
        #expect(roundTripped == decoded)
    }

    @Test("lossless round-trip of unknown stop reasons")
    func unknownStopReasonRoundTrip() throws {
        let json = "\"future_stop_signal\""
        let data = try #require(json.data(using: .utf8))
        let decoded = try decoder.decode(ACPStopReason.self, from: data)
        #expect(decoded == .other("future_stop_signal"))

        let encodedData = try encoder.encode(decoded)
        let roundTripped = try decoder.decode(ACPStopReason.self, from: encodedData)
        #expect(roundTripped == decoded)
    }

    @Test("prompt request and response insertion envelopes match v2 schema")
    func promptLifecycleEnvelopes() throws {
        let promptReq = ACPPromptRequest(
            sessionId: "sess-123",
            prompt: [
                .text(ACPTextContent(text: "Hello ACP v2")),
            ],
            meta: ["clientTurnId": .string("turn-001")]
        )
        let reqData = try encoder.encode(promptReq)
        let decodedReq = try decoder.decode(ACPPromptRequest.self, from: reqData)
        #expect(decodedReq.sessionId == "sess-123")
        #expect(decodedReq.prompt.count == 1)
        #expect(decodedReq.meta?["clientTurnId"] == .string("turn-001"))

        let promptResp = ACPPromptResponse(
            messageId: "msg-999",
            meta: ["turnDurationMs": .int(150)]
        )
        let respData = try encoder.encode(promptResp)
        let decodedResp = try decoder.decode(ACPPromptResponse.self, from: respData)
        #expect(decodedResp.messageId == "msg-999")
        #expect(decodedResp.meta?["turnDurationMs"] == .int(150))
    }

    @Test("fitness check: Sources contains no ACP v1 method names or aptove dependencies")
    func fitnessSourcesHaveNoV1Artifacts() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesURL = rootURL.appendingPathComponent("Sources")

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: sourcesURL, includingPropertiesForKeys: [.isRegularFileKey])

        var scannedFiles = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            scannedFiles += 1
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!content.contains("import ACP"), "File \(fileURL.lastPathComponent) contains forbidden 'import ACP'")
            #expect(!content.contains("aptove"), "File \(fileURL.lastPathComponent) contains forbidden 'aptove'")
            #expect(!content.contains("session/load"), "File \(fileURL.lastPathComponent) contains forbidden 'session/load'")
            #expect(!content.contains("loadSession:"), "File \(fileURL.lastPathComponent) contains forbidden 'loadSession:'")
        }
        #expect(scannedFiles > 0, "Should have scanned at least one Swift file in Sources/")
    }
}
