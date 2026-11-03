// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Waits for an operation for a bounded time, even when the operation never
/// returns and ignores cancellation.
///
/// A `withTaskGroup` race does not bound anything in that case: the group
/// cannot return until every child has finished, so a child that ignores
/// cancellation holds the caller. This helper does not join the operation. It
/// resumes the caller from whichever of the operation or the timer finishes
/// first and abandons the other.
enum BoundedWait {
    /// Returns the operation's value, or `nil` once `timeout` has elapsed.
    ///
    /// On timeout the operation keeps running unowned. The caller decides what
    /// that means and must not depend on the operation finishing.
    static func run<Value: Sendable>(
        timeout: Duration,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = ResumeOnce(continuation)
            // The timer runs outside any actor, so a busy actor cannot delay it.
            once.timer = Task.detached {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
            Task.detached { once.resume(await operation()) }
        }
    }

    /// Resumes a continuation at most once and cancels the timer when the
    /// operation wins.
    private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        private var cancelsTimer = false
        private var storedTimer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }

        var timer: Task<Void, Never>? {
            get { lock.withLock { storedTimer } }
            set {
                let cancel = lock.withLock { () -> Bool in
                    storedTimer = newValue
                    return cancelsTimer
                }
                if cancel { newValue?.cancel() }
            }
        }

        func resume(_ value: Value?) {
            let (pending, timer) = lock.withLock { () -> (CheckedContinuation<Value?, Never>?, Task<Void, Never>?) in
                let pending = continuation
                continuation = nil
                if value != nil { cancelsTimer = true }
                return (pending, storedTimer)
            }
            if value != nil { timer?.cancel() }
            pending?.resume(returning: value)
        }
    }
}
