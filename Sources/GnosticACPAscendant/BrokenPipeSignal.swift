// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Makes a write to a closed pipe fail with `EPIPE` instead of ending the process.
///
/// The process-wide signal disposition stays unchanged, so a spawned Runtime
/// never inherits an ignored `SIGPIPE`.
enum BrokenPipeSignal {
    /// Darwin raises `SIGPIPE` on the whole process, so a thread mask can't
    /// contain it there. This per-descriptor flag does.
    static func disable(onWriteEnd descriptor: Int32) {
        #if canImport(Darwin)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    /// Blocks `SIGPIPE` for this thread while `operation` runs. Linux directs the
    /// signal at the writing thread. It stays pending while blocked, so it is
    /// drained before the mask returns; otherwise it would end the process then.
    static func suppressed<T>(_ operation: () throws -> T) rethrows -> T {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        defer {
            var pending = sigset_t()
            sigemptyset(&pending)
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) == 1 {
                var received: Int32 = 0
                sigwait(&pending, &received)
            }
            pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        return try operation()
    }
}
