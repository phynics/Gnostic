// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM digest")
struct RLMDigestTests {
    @Test("matches the empty-message SHA-256 vector")
    func emptyVector() {
        #expect(RLMDigest.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("matches the abc SHA-256 vector")
    func abcVector() {
        #expect(RLMDigest.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("matches the two-block SHA-256 vector")
    func twoBlockVector() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(RLMDigest.sha256Hex(message) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test("matches the multi-block SHA-256 vector")
    func multiBlockVector() {
        let message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
            + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        #expect(RLMDigest.sha256Hex(message) == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
    }

    @Test("is deterministic for byte input")
    func deterministic() {
        let bytes: [UInt8] = [0, 1, 2, 255, 128, 64]
        #expect(RLMDigest.sha256Hex(bytes) == RLMDigest.sha256Hex(bytes))
    }
}
