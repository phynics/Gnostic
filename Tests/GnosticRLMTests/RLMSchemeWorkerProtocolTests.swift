// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM worker frame protocol")
struct RLMSchemeWorkerProtocolTests {
    private let runID = "run-1"

    @Test("round-trips every frame kind")
    func roundTrips() throws {
        let frames: [RLMSchemeWorkerFrame] = [
            .initialize(RLMSchemeInitialize(
                runID: runID, profile: "gnostic-rlm-scheme-0",
                maxHeapBytes: 1, maxOutputBytes: 2, timeLimitSeconds: 0.5, allocationLimitBytes: 3
            )),
            .evaluate(RLMSchemeEvaluate(runID: runID, cellID: 7, source: "(finish \"a\" (list))")),
            .hostResult(RLMSchemeHostResult(runID: runID, callID: 12, value: .list([.string("x")]))),
            .hostError(RLMSchemeHostError(runID: runID, callID: 12, message: "boom")),
            .cancel(runID: runID),
            .shutdown(runID: runID),
            .ready(RLMSchemeReady(
                runID: runID, environmentKeys: ["PATH", "LC_ALL"], openFileDescriptorCount: 8,
                cpuLimitSeconds: 7, addressSpaceBytes: 256
            )),
            .hostCall(RLMSchemeHostCall(
                runID: runID, callID: 3, name: "lm-query",
                arguments: [.string("prompt"), .symbol("fast")]
            )),
            .evaluated(RLMSchemeEvaluated(runID: runID, cellID: 2, value: .integer(42), output: "")),
            .evaluated(RLMSchemeEvaluated(runID: runID, cellID: 2, value: nil, output: "printed")),
            .finished(RLMSchemeFinished(runID: runID, answer: "answer", evidenceIDs: ["c-1", "c-2"])),
            .failed(RLMSchemeEvaluationFailure(runID: runID, cellID: 4, message: "limit")),
        ]
        for frame in frames {
            let encoded = try RLMSchemeWorkerCodec.encode(frame)
            #expect(encoded.count > 4)
            let decoded = try RLMSchemeWorkerCodec.decode(Array(encoded.dropFirst(4)))
            #expect(decoded == frame)
        }
    }

    @Test("prefixes each frame with a big-endian 32-bit length")
    func framing() throws {
        let encoded = try RLMSchemeWorkerCodec.encode(.cancel(runID: runID))
        let bytes = [UInt8](encoded)
        let declared = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        #expect(Int(declared) == encoded.count - 4)
    }

    @Test("decodes worker-produced text")
    func decodesWorkerText() throws {
        let ready = try RLMSchemeWorkerCodec.decode(Array(
            "(ready runID \"r\" environmentKeys (\"PATH\") openFileDescriptorCount 8 cpuLimitSeconds 7 addressSpaceBytes 256)".utf8
        ))
        #expect(ready == .ready(RLMSchemeReady(
            runID: "r", environmentKeys: ["PATH"], openFileDescriptorCount: 8,
            cpuLimitSeconds: 7, addressSpaceBytes: 256
        )))

        let hostCall = try RLMSchemeWorkerCodec.decode(Array(
            "(hostCall runID \"r\" callID 1 name \"corpus-search\" arguments (\"q\" 4))".utf8
        ))
        #expect(hostCall == .hostCall(RLMSchemeHostCall(
            runID: "r", callID: 1, name: "corpus-search", arguments: [.string("q"), .integer(4)]
        )))

        let finished = try RLMSchemeWorkerCodec.decode(Array(
            "(finished runID \"r\" answer \"a\" evidenceIDs (\"c-1\"))".utf8
        ))
        #expect(finished == .finished(RLMSchemeFinished(runID: "r", answer: "a", evidenceIDs: ["c-1"])))
    }

    @Test("the capped encoder rejects payloads over the configured limit")
    func cappedEncoder() throws {
        let frame = RLMSchemeWorkerFrame.cancel(runID: "r")
        let defaultEncoded = try RLMSchemeWorkerCodec.encode(frame)
        let cappedEncoded = try RLMSchemeWorkerCodec.encode(frame, maxFrameBytes: 1_024)
        #expect(cappedEncoded == defaultEncoded)
        #expect(throws: RLMSchemeProtocolError.frameTooLarge(limit: 4)) {
            try RLMSchemeWorkerCodec.encode(frame, maxFrameBytes: 4)
        }
        #expect(throws: RLMSchemeProtocolError.frameTooLarge(limit: 2)) {
            try RLMSchemeWorkerCodec.framed([1, 2, 3], maxFrameBytes: 2)
        }
        #expect(try RLMSchemeWorkerCodec.framed([1, 2, 3], maxFrameBytes: 3).count == 7)
    }

    @Test("rejects oversized, unknown, and incomplete frames")
    func rejectsBadFrames() {
        #expect(throws: RLMSchemeProtocolError.frameTooLarge(limit: RLMSchemeWorkerCodec.maxFrameBytes)) {
            try RLMSchemeWorkerCodec.framed([UInt8](repeating: 0, count: RLMSchemeWorkerCodec.maxFrameBytes + 1))
        }
        #expect(throws: RLMSchemeProtocolError.unknownFrameType("bogus")) {
            try RLMSchemeWorkerCodec.decode(Array("(bogus runID \"r\")".utf8))
        }
        #expect(throws: RLMSchemeProtocolError.missingField("source")) {
            try RLMSchemeWorkerCodec.decode(Array("(evaluate runID \"r\" cellID 1)".utf8))
        }
        #expect(throws: RLMSchemeProtocolError.unexpectedFieldType("cellID")) {
            try RLMSchemeWorkerCodec.decode(Array("(evaluate runID \"r\" cellID \"x\" source \"y\")".utf8))
        }
    }
}
