// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLMChibi

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite("RLM Chibi process signal scope", .serialized)
struct RLMChibiProcessSignalsTests {
    private func sigpipeIsBlocked() -> Bool {
        var current = sigset_t()
        sigemptyset(&current)
        pthread_sigmask(SIG_BLOCK, nil, &current)
        return sigismember(&current, SIGPIPE) == 1
    }

    private func unblockSIGPIPE() {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGPIPE)
        _ = pthread_sigmask(SIG_UNBLOCK, &set, nil)
    }

    @Test("blocks SIGPIPE only inside the scope and restores the mask")
    func scopesAndRestores() {
        unblockSIGPIPE()
        let baseline = sigpipeIsBlocked()

        let blockedInside = RLMChibiProcessSignals.withoutBrokenPipeSignal { sigpipeIsBlocked() }
        #expect(blockedInside)
        #expect(sigpipeIsBlocked() == baseline)
    }

    @Test("restores the mask when the operation throws")
    func restoresOnThrow() {
        struct ScopeError: Error {}
        unblockSIGPIPE()
        let baseline = sigpipeIsBlocked()

        #expect(throws: ScopeError.self) {
            try RLMChibiProcessSignals.withoutBrokenPipeSignal { throw ScopeError() }
        }
        #expect(sigpipeIsBlocked() == baseline)
    }
}
