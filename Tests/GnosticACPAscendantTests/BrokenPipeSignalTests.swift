// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPAscendant
import Testing

#if os(Linux)
/// `BrokenPipeSignal` removes only the signal its own write raised (issue #696).
/// These run on one thread, because the mask and thread-pending signals belong to it.
@Suite("Broken pipe signal", .serialized)
struct BrokenPipeSignalTests {
    private func writeToClosedPipe() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        try BrokenPipeSignal.suppressed {
            try pipe.fileHandleForWriting.write(contentsOf: Data([0x41]))
        }
    }

    private func isPending(_ signal: Int32) -> Bool {
        var pending = sigset_t()
        sigpending(&pending)
        return sigismember(&pending, signal) == 1
    }

    @Test("a write to a closed pipe throws and leaves no signal pending")
    func closedPipeThrows() {
        #expect(throws: (any Error).self) { try writeToClosedPipe() }
        #expect(!isPending(SIGPIPE))
    }

    @Test("a successful write returns without waiting for a signal")
    func successfulWriteDoesNotWait() throws {
        let pipe = Pipe()
        try BrokenPipeSignal.suppressed {
            try pipe.fileHandleForWriting.write(contentsOf: Data([0x41]))
        }
        #expect(!isPending(SIGPIPE))
    }

    @Test("another blocked signal stays pending, and SIGPIPE is still removed")
    func otherSignalsAreUntouched() {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGUSR1)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        pthread_kill(pthread_self(), SIGUSR1)
        defer {
            var received: Int32 = 0
            sigwait(&blocked, &received)
            pthread_sigmask(SIG_SETMASK, &previous, nil)
        }

        #expect(throws: (any Error).self) { try writeToClosedPipe() }
        #expect(isPending(SIGUSR1))
        #expect(!isPending(SIGPIPE))
    }
}
#endif
