// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
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

    /// Runs one write that can hit a closed pipe. On Linux the signal goes to the
    /// writing thread, so it is blocked for this thread and removed before the
    /// mask returns; otherwise it would end the process then. Only a `SIGPIPE`
    /// this write raised is removed, and removing it never waits, because another
    /// thread may already have taken one pending for the process.
    static func suppressed<T>(_ operation: () throws -> T) rethrows -> T {
        #if os(Linux)
        var onlyBrokenPipe = sigset_t()
        sigemptyset(&onlyBrokenPipe)
        sigaddset(&onlyBrokenPipe, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &onlyBrokenPipe, &previous)
        var pendingBefore = sigset_t()
        sigpending(&pendingBefore)
        let wasPending = sigismember(&pendingBefore, SIGPIPE) == 1
        defer {
            if !wasPending {
                var immediately = timespec(tv_sec: 0, tv_nsec: 0)
                _ = sigtimedwait(&onlyBrokenPipe, nil, &immediately)
            }
            pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        #endif
        return try operation()
    }

    /// Writes to this process's stderr. A reader that has gone away loses the
    /// output, and must not end the host.
    static func writeToStandardError(_ data: Data) {
        let handle = FileHandle.standardError
        disable(onWriteEnd: handle.fileDescriptor)
        suppressed { try? handle.write(contentsOf: data) }
    }
}
