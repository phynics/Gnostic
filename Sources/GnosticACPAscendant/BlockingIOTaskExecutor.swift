// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Dispatch

/// Runs one task that makes blocking system calls on its own serial queue.
///
/// A blocking call on the Swift cooperative pool parks one of its threads, and
/// the pool has only as many threads as the machine has CPUs. Enough such tasks
/// stop every other task in the process, so each long-lived blocking loop uses
/// its own instance of this executor.
final class BlockingIOTaskExecutor: TaskExecutor {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}
