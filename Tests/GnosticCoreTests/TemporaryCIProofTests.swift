// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

@Suite("Temporary CI proof")
struct TemporaryCIProofTests {
    @Test("deliberately failing test proving CI blocks a red commit")
    func deliberateFailure() {
        #expect(Bool(false), "This test exists only to prove the workflow fails. It is reverted in the next commit.")
    }
}
