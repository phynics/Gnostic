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
///
/// The timer is a Dispatch work item, not a Swift task. A Swift task timer
/// runs on the cooperative pool, so a pool whose threads are all blocked would
/// stop the timer that is meant to bound the blocked caller.
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
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            let timer = DispatchWorkItem { once.resume(nil) }
            once.timer = timer
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
            Task.detached { once.resume(await operation()) }
        }
    }

    /// Resumes a continuation at most once and cancels the timer when the
    /// operation wins.
    private final class ResumeOnce<Value: Sendable>: @unchecked Sendable { // SAFETY: All mutable state is read or written while holding the lock.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        private var cancelsTimer = false
        private var storedTimer: DispatchWorkItem?

        init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }

        var timer: DispatchWorkItem? {
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
            let (pending, timer) = lock.withLock { () -> (CheckedContinuation<Value?, Never>?, DispatchWorkItem?) in
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
