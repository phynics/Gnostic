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
    ///
    /// - Parameter observeState: Receives the wait's internal state object
    ///   once, so a test can check that it is released.
    static func run<Value: Sendable>(
        timeout: Duration,
        observeState: (@Sendable (AnyObject) -> Void)? = nil,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = ResumeOnce(continuation)
            observeState?(once)
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            // The work item holds `once` weakly. `once` holds the work item
            // until it resumes, so a strong capture would be a retain cycle.
            let timer = DispatchWorkItem { [weak once] in once?.resume(nil) }
            once.attach(timer)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
            Task.detached { once.resume(await operation()) }
        }
    }

    /// Resumes a continuation at most once and cancels the timer when the
    /// operation wins.
    private final class ResumeOnce<Value: Sendable>: @unchecked Sendable { // SAFETY: All mutable state is read or written while holding the lock.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        private var timer: DispatchWorkItem?
        private var resumed = false

        init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }

        /// Stores the timer, or cancels it at once if the wait already ended.
        func attach(_ item: DispatchWorkItem) {
            let alreadyResumed = lock.withLock { () -> Bool in
                if !resumed { timer = item }
                return resumed
            }
            if alreadyResumed { item.cancel() }
        }

        func resume(_ value: Value?) {
            // Take and clear both references under the lock, then act outside it.
            let (pending, item) = lock.withLock { () -> (CheckedContinuation<Value?, Never>?, DispatchWorkItem?) in
                resumed = true
                let pending = continuation
                let item = timer
                continuation = nil
                timer = nil
                return (pending, item)
            }
            if value != nil { item?.cancel() }
            pending?.resume(returning: value)
        }
    }
}
