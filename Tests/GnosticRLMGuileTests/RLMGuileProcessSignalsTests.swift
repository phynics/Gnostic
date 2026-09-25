// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLMGuile

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite("RLM Guile process signal scope", .serialized)
struct RLMGuileProcessSignalsTests {
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

        let blockedInside = RLMGuileProcessSignals.withoutBrokenPipeSignal { sigpipeIsBlocked() }
        #expect(blockedInside)
        #expect(sigpipeIsBlocked() == baseline)
    }

    @Test("restores the mask when the operation throws")
    func restoresOnThrow() {
        struct ScopeError: Error {}
        unblockSIGPIPE()
        let baseline = sigpipeIsBlocked()

        #expect(throws: ScopeError.self) {
            try RLMGuileProcessSignals.withoutBrokenPipeSignal { throw ScopeError() }
        }
        #expect(sigpipeIsBlocked() == baseline)
    }

    #if canImport(Darwin)
    @Test("a marked write end reports EPIPE instead of raising SIGPIPE")
    func markedWriteEndDoesNotSignal() {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer { close(descriptors[1]) }
        close(descriptors[0])

        RLMGuileProcessSignals.disableBrokenPipeSignal(onWriteEnd: descriptors[1])
        #expect(fcntl(descriptors[1], F_GETNOSIGPIPE) == 1)

        // Deliberately unmasked: Darwin raises a broken-pipe SIGPIPE on the
        // whole process, so without the flag this write kills the test run.
        unblockSIGPIPE()
        var byte: UInt8 = 0
        let written = write(descriptors[1], &byte, 1)
        let failure = errno
        #expect(written == -1)
        #expect(failure == EPIPE)
    }
    #endif
}
