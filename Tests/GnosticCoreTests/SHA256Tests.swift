// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

import GnosticCore

@Suite("Package SHA-256")
struct SHA256Tests {
    @Test("matches the empty-message SHA-256 vector")
    func emptyVector() {
        #expect(SHA256.hexDigest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("matches the abc SHA-256 vector")
    func abcVector() {
        #expect(SHA256.hexDigest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("matches the two-block SHA-256 vector")
    func twoBlockVector() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(SHA256.hexDigest(message) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test("matches the multi-block SHA-256 vector")
    func multiBlockVector() {
        let message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
            + "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        #expect(SHA256.hexDigest(message) == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
    }

    @Test("the byte and string spellings agree, and the digest is 32 bytes")
    func byteAndStringSpellingsAgree() {
        let bytes: [UInt8] = Array("abc".utf8)
        #expect(SHA256.digest(bytes).count == 32)
        #expect(SHA256.hexDigest(bytes) == SHA256.hexDigest("abc"))
        #expect(SHA256.digest(bytes) == SHA256.digest("abc"))
    }
}
