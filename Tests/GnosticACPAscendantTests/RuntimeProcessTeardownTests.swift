// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPAscendant
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runtime teardown must end within its bounds on the main actor, even when
/// the exit report of the Runtime process never arrives (#745).
///
/// macOS `Process.waitUntilExit()` can wait forever when its run-loop wake-up
/// is lost, and Linux corelibs cannot reproduce that. These tests stand in for
/// the loss: `ForeignLeaderProcess` reports no exit, stays `isRunning`, and its
/// `waitUntilExit()` blocks like the lost wake-up until a pool-independent
/// timer releases it. Only `waitpid` can see the leader exit.
@Suite("Runtime process teardown", .serialized)
@MainActor
struct RuntimeProcessTeardownTests {
    private static let bounds = RuntimeProcessTeardownBounds(
        termGraceNanoseconds: 300_000_000,
        killGraceNanoseconds: 300_000_000,
        groupExitNanoseconds: 300_000_000
    )
    /// The whole teardown stays well below this. A blocked call lasts
    /// `ForeignLeaderProcess.lostWakeupSeconds`, so the check separates them.
    private static let completionLimit: Duration = .seconds(3)

    @Test("a lost exit report after SIGTERM still ends teardown, and waitpid reaps the leader")
    func lostReportAfterTerm() async throws {
        let child = try SpawnedChild.spawn(script: "exec sleep 60", ownGroup: true)
        defer { child.cleanup() }
        let leader = ForeignLeaderProcess(pid: child.pid)
        let teardown = RuntimeProcessTeardown(process: leader, processGroupID: child.pid)

        let (outcome, elapsed) = await Self.timedStop(teardown, leader: leader)

        #expect(elapsed < Self.completionLimit, "teardown blocked for \(elapsed)")
        #expect(leader.waitUntilExitCalls == 0, "teardown called waitUntilExit()")
        #expect(outcome.leaderExited && outcome.groupGone)
        #expect(!child.isAlive(), "the leader is still a process or a zombie")
        #expect(teardown.leaderWasReaped)
    }

    @Test("a Runtime that ignores SIGTERM is killed, and a lost exit report does not block the main actor")
    func lostReportAfterKill() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("teardown-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let child = try SpawnedChild.spawn(
            script: "trap '' TERM; : > '\(marker.path)'; while :; do sleep 1; done",
            ownGroup: true
        )
        defer { child.cleanup() }
        try await Self.waitForFile(marker)
        let leader = ForeignLeaderProcess(pid: child.pid)
        let teardown = RuntimeProcessTeardown(process: leader, processGroupID: child.pid)

        let (outcome, elapsed) = await Self.timedStop(teardown, leader: leader)

        #expect(elapsed < Self.completionLimit, "teardown blocked for \(elapsed) after SIGKILL")
        #expect(leader.waitUntilExitCalls == 0, "teardown called waitUntilExit() after SIGKILL")
        #expect(outcome.leaderExited && outcome.groupGone)
        #expect(!child.isAlive())
        #expect(kill(-child.pid, 0) != 0 && errno == ESRCH, "the process group survived teardown")
    }

    @Test("a leader that never exits is abandoned at the bound, with the report saying so")
    func leaderThatNeverExits() async throws {
        // The group is already gone, so the leader falls outside it and
        // nothing signals it: it models a process that cannot be stopped.
        let deadGroup = try SpawnedChild.spawn(script: "exit 0", ownGroup: true)
        deadGroup.waitUntilReaped()
        let child = try SpawnedChild.spawn(script: "exec sleep 60", ownGroup: true)
        defer { child.cleanup() }
        let leader = ForeignLeaderProcess(pid: child.pid)
        let teardown = RuntimeProcessTeardown(process: leader, processGroupID: deadGroup.pid)

        let (outcome, elapsed) = await Self.timedStop(teardown, leader: leader)

        #expect(elapsed < Self.completionLimit, "teardown blocked for \(elapsed)")
        #expect(leader.waitUntilExitCalls == 0, "teardown called waitUntilExit()")
        #expect(!outcome.leaderExited)
        #expect(outcome.incompleteDescription != nil)
        #expect(child.isAlive(), "the leader outside the group must not be reaped while it runs")
        #expect(!teardown.leaderWasReaped)
    }

    @Test("without a process group, a leader that ignores SIGTERM is killed within the bound")
    func noProcessGroupLostReport() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("teardown-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let child = try SpawnedChild.spawn(
            script: "trap '' TERM; : > '\(marker.path)'; while :; do sleep 1; done",
            ownGroup: false
        )
        defer { child.cleanup() }
        try await Self.waitForFile(marker)
        let leader = ForeignLeaderProcess(pid: child.pid)
        let teardown = RuntimeProcessTeardown(process: leader, processGroupID: nil)

        let (outcome, elapsed) = await Self.timedStop(teardown, leader: leader)

        #expect(elapsed < Self.completionLimit, "teardown blocked for \(elapsed)")
        #expect(leader.waitUntilExitCalls == 0, "teardown called waitUntilExit()")
        #expect(outcome.leaderExited)
        #expect(!child.isAlive())
    }

    @Test("a leader that another party already reaped is not reaped twice and ends teardown at once")
    func leaderReapedElsewhere() async throws {
        let child = try SpawnedChild.spawn(script: "exit 0", ownGroup: true)
        child.waitUntilReaped()
        let leader = ForeignLeaderProcess(pid: child.pid)
        let teardown = RuntimeProcessTeardown(process: leader, processGroupID: child.pid)

        let (outcome, elapsed) = await Self.timedStop(teardown, leader: leader)

        #expect(elapsed < .seconds(1), "teardown blocked for \(elapsed)")
        #expect(leader.waitUntilExitCalls == 0)
        #expect(outcome.leaderExited && outcome.groupGone)
        #expect(teardown.leaderWasReaped)
        #expect(!teardown.isLeaderRunning, "a reaped leader must not be probed again")
    }

    // MARK: - Helpers

    /// Runs `stop()`, failing with a message from a pool-independent timer if it
    /// does not return, so a regression cannot hang a CI job in silence.
    private static func timedStop(
        _ teardown: RuntimeProcessTeardown,
        leader: ForeignLeaderProcess
    ) async -> (RuntimeProcessTeardownOutcome, Duration) {
        let watchdog = DispatchWorkItem {
            Issue.record("Runtime teardown did not return within 30 s; releasing the simulated lost wake-up")
            leader.releaseLostWakeup()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await teardown.stop(bounds: bounds)
        return (outcome, clock.now - start)
    }

    private static func waitForFile(_ url: URL) async throws {
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: url.path), "the test child never became ready")
    }
}

/// A `Process` for a child that Foundation does not know about. It never
/// reports an exit and always claims to run, as a `Process` does when its exit
/// notification is lost. Its `waitUntilExit()` waits like the lost wake-up.
private final class ForeignLeaderProcess: Process, @unchecked Sendable {
    /// How long a call to `waitUntilExit()` lasts. It is a test cap, not a bound the product relies on.
    static let lostWakeupSeconds: Double = 8

    private let pid: pid_t
    private let lock = NSLock()
    private var calls = 0
    private let released = DispatchSemaphore(value: 0)

    init(pid: pid_t) {
        self.pid = pid
        super.init()
    }

    var waitUntilExitCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func releaseLostWakeup() { released.signal() }

    override var processIdentifier: Int32 { pid }
    override var isRunning: Bool { true }
    override var terminationHandler: (@Sendable (Process) -> Void)? {
        get { nil }
        set { _ = newValue }
    }

    override func terminate() { _ = kill(pid, SIGTERM) }

    override func waitUntilExit() {
        lock.lock()
        calls += 1
        lock.unlock()
        _ = released.wait(timeout: .now() + Self.lostWakeupSeconds)
    }
}

/// A child started with `posix_spawn`, optionally as the leader of a new process group.
private struct SpawnedChild {
    let pid: pid_t

    static func spawn(script: String, ownGroup: Bool) throws -> SpawnedChild {
        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        if ownGroup {
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        let arguments = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", nil, &attributes, arguments, environ)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return SpawnedChild(pid: pid)
    }

    /// True while the PID names a process or an unreaped zombie.
    func isAlive() -> Bool { kill(pid, 0) == 0 }

    func waitUntilReaped() {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    func cleanup() {
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
    }
}
