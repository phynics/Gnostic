// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Synchronization

/// A monotonic time source for deterministic wall-time accounting.
public protocol RLMClock: Sendable {
    func now() -> Duration
}

/// The production clock, anchored at construction.
public struct RLMSystemClock: RLMClock {
    private let clock: ContinuousClock
    private let start: ContinuousClock.Instant

    public init(clock: ContinuousClock = ContinuousClock()) {
        self.clock = clock
        self.start = clock.now
    }

    public func now() -> Duration {
        start.duration(to: clock.now)
    }
}

/// A manually advanced clock for deterministic wall-time tests.
public final class RLMTestClock: RLMClock, Sendable {
    private let time: Mutex<Duration>

    public init(start: Duration = .zero) {
        self.time = Mutex(start)
    }

    public func now() -> Duration {
        time.withLock { $0 }
    }

    public func advance(by duration: Duration) {
        time.withLock { $0 += duration }
    }
}

/// Estimates model tokens from text without a provider tokenizer.
public protocol RLMTokenEstimator: Sendable {
    func estimateTokens(for text: String) -> Int
}

/// A deterministic estimator of roughly four UTF-8 bytes per token.
public struct RLMCharacterTokenEstimator: RLMTokenEstimator {
    public init() {}

    public func estimateTokens(for text: String) -> Int {
        max(1, (text.utf8.count + 3) / 4)
    }
}

/// A thread-safe, one-way cancellation flag owned by a run's caller.
public final class RLMCancellationToken: Sendable {
    private let flag: Mutex<Bool>

    public init(cancelled: Bool = false) {
        self.flag = Mutex(cancelled)
    }

    public func cancel() {
        flag.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        flag.withLock { $0 }
    }
}

/// A monotonic run generation used to fence late results.
///
/// A run captures its generation once. Any result observed after the fence is
/// invalidated belongs to an older generation and must be discarded.
public final class RLMRunFence: Sendable {
    private let generation: Mutex<UInt64>

    public init(generation: UInt64 = 0) {
        self.generation = Mutex(generation)
    }

    public var current: UInt64 {
        generation.withLock { $0 }
    }

    @discardableResult
    public func invalidate() -> UInt64 {
        generation.withLock {
            $0 += 1
            return $0
        }
    }

    public func accepts(_ value: UInt64) -> Bool {
        generation.withLock { $0 == value }
    }
}
