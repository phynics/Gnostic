// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs one pipe write with `SIGPIPE` blocked for the calling thread only.
///
/// The block is thread-scoped, so the process-wide disposition is never
/// changed and the host cannot inherit an ignore that outlives the worker.
/// A write to a broken pipe returns `EPIPE`; the kernel leaves the matching
/// `SIGPIPE` pending while it is blocked, so the pending signal is drained
/// before the mask is restored. Restoring the mask with a pending `SIGPIPE`
/// would deliver it and terminate the process.
package enum RLMProcessSignals {
    package static func withoutBrokenPipeSignal<T>(_ operation: () throws -> T) rethrows -> T {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer {
            drainPendingSIGPIPE()
            pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        return try operation()
    }

    /// Makes a write to `descriptor` after its reader exits fail with `EPIPE`
    /// instead of raising `SIGPIPE`.
    ///
    /// Darwin raises a broken-pipe `SIGPIPE` on the whole process, not on the
    /// writing thread, so any thread that has not blocked it can take it and
    /// terminate the host. The thread mask in ``withoutBrokenPipeSignal(_:)``
    /// cannot contain that; the per-descriptor flag does. Linux directs the
    /// signal at the writing thread, where the mask is sufficient (#404).
    package static func disableBrokenPipeSignal(onWriteEnd descriptor: Int32) {
        #if canImport(Darwin)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    private static func drainPendingSIGPIPE() {
        var pending = sigset_t()
        sigemptyset(&pending)
        sigpending(&pending)
        guard sigismember(&pending, SIGPIPE) == 1 else { return }
        var received: Int32 = 0
        sigwait(&pending, &received)
    }
}
