// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Shutdown while the broker connection is being re-established.
///
/// Axoloty's `reconnect()` ignores task cancellation and suspends several
/// times before it opens the transport. These tests prove that `stopAndWait()`
/// joins that attempt and leaves no broker connection behind.
///
/// Every scenario runs under a `Watchdog` and prints `TRACE` lines, because a
/// stall on macOS CI (#738) has held the job for 30 minutes with no cause in
/// the log. The scenarios are free functions so the opt-in repeat suite below
/// can run them again in one process.
@Suite("Reconnect shutdown", .serialized)
struct ReconnectShutdownTests {
    @Test("shutdown joins a reconnect attempt that resumes after the runtime stopped", .timeLimit(.minutes(1)))
    @MainActor
    func shutdownJoinsAttemptResumingAfterStop() async throws {
        try await scenarioJoinsAttemptResumingAfterStop()
    }

    @Test("a reconnect that never returns does not hold shutdown past its bound", .timeLimit(.minutes(1)))
    @MainActor
    func attemptThatNeverReturnsDoesNotHoldShutdown() async throws {
        try await scenarioAttemptNeverReturns()
    }

    @Test("a teardown call that never returns does not hold stopAndWait", .timeLimit(.minutes(1)))
    @MainActor
    func teardownThatNeverReturnsDoesNotHoldShutdown() async throws {
        try await scenarioTeardownNeverReturns()
    }

    @Test("shutdown unblocks a real reconnect stalled in the MQTT handshake", .timeLimit(.minutes(1)))
    @MainActor
    func shutdownDuringReconnectHandshake() async throws {
        try await scenarioHandshakeStall()
    }

    @Test("the watchdog fires while the main actor is blocked")
    @MainActor
    func watchdogFiresWhileMainActorIsBlocked() {
        let fired = DispatchSemaphore(value: 0)
        let watchdog = Watchdog.arm("self-test", seconds: 0.2) { _ in fired.signal() }
        defer { watchdog.disarm() }
        // Block this thread, the main actor, without suspending.
        let result = fired.wait(timeout: .now() + 5)
        #expect(result == .success, "The watchdog did not fire on its own thread")
    }

    @Test("the watchdog report names the last trace line")
    func watchdogReportNamesTheLastTraceLine() {
        trace("report-test: marker line")
        let report = Watchdog.report("report-test")
        #expect(report.contains("LAST TRACE:"))
        #expect(report.contains("report-test: marker line"))
    }

    @Test("a diagnostic subprocess that does not exit is killed at its bound")
    func diagnosticSubprocessIsBounded() {
        let started = ContinuousClock.now
        let outcome = Watchdog.runBounded(["/bin/sleep", "30"], bound: 1)
        #expect(outcome.timedOut)
        #expect(ContinuousClock.now - started < .seconds(5), "The subprocess outlived its bound")
        let quick = Watchdog.runBounded(["/bin/echo", "hello"], bound: 5)
        #expect(!quick.timedOut)
        #expect(quick.output.contains("hello"))
    }

    @Test("the watchdog budget fits inside the test limit and above a successful run")
    func watchdogBudgetFits() {
        // The report must finish before Swift Testing's limit fires.
        #expect(Budget.watchdog + Budget.diagnostics + Budget.schedulingMargin <= Budget.testLimit)
        // And the watchdog must not fire on a slow but successful run.
        #expect(Budget.watchdog >= 1.5 * Budget.worstSuccessfulPath)
    }

    @Test("a bounded wait returns although its operation ignores cancellation and never finishes")
    func boundedWaitDoesNotJoinItsOperation() async {
        let never = Gate()
        let started = ContinuousClock.now
        let result: Int? = await BoundedWait.run(timeout: .milliseconds(200)) {
            await never.wait()
            return 1
        }
        #expect(result == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
        let value: Int? = await BoundedWait.run(timeout: .seconds(5)) { 7 }
        #expect(value == 7)
        await never.open()
    }

    @Test("a bounded wait releases its state when the operation finishes first")
    func boundedWaitReleasesStateWhenOperationWins() async {
        let state = WeakBox()
        // A long timeout: the cancelled timer stays queued, and must not hold the state.
        let value: Int? = await BoundedWait.run(timeout: .seconds(60), observeState: { state.observe($0) }) { 7 }
        #expect(value == 7)
        #expect(await state.isReleased(within: .seconds(3)), "The wait state was still retained after the operation won")
    }

    @Test("a bounded wait releases its state after a timeout once the operation ends")
    func boundedWaitReleasesStateAfterTimeout() async {
        let state = WeakBox()
        let gate = Gate()
        let value: Int? = await BoundedWait.run(timeout: .milliseconds(100), observeState: { state.observe($0) }) {
            await gate.wait()
            return 1
        }
        #expect(value == nil)
        await gate.open()
        #expect(await state.isReleased(within: .seconds(3)), "The wait state was still retained after the abandoned operation ended")
    }
}

/// Runs the shutdown scenarios again in one process. Off by default: set
/// `GNOSTIC_RECONNECT_SHUTDOWN_REPEAT=<n>` to run them `n` times, to make a
/// rare stall more likely.
///
///     GNOSTIC_RECONNECT_SHUTDOWN_REPEAT=50 swift test --filter ReconnectShutdownRepeat
///
/// It exercises the same scenario functions as `ReconnectShutdownTests`, so it
/// changes nothing under test. CI does not set the variable.
private let repeatCount = Int(ProcessInfo.processInfo.environment["GNOSTIC_RECONNECT_SHUTDOWN_REPEAT"] ?? "") ?? 0

@Suite("ReconnectShutdownRepeat", .serialized, .enabled(if: repeatCount > 0))
struct ReconnectShutdownRepeatTests {
    @Test("the shutdown scenarios repeat in one process", .timeLimit(.minutes(max(1, repeatCount))))
    @MainActor
    func repeatsScenarios() async throws {
        for iteration in 1...max(1, repeatCount) {
            trace("repeat: iteration \(iteration) of \(repeatCount) begins")
            try await scenarioJoinsAttemptResumingAfterStop()
            try await scenarioAttemptNeverReturns()
            try await scenarioTeardownNeverReturns()
            try await scenarioHandshakeStall()
            trace("repeat: iteration \(iteration) of \(repeatCount) ends")
        }
    }
}

// MARK: - Scenarios

/// Runs a scenario body under a watchdog, with trace lines at its edges.
@MainActor
private func watched(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
    let watchdog = Watchdog.arm(name, seconds: Budget.watchdog)
    trace("\(name): begin")
    defer {
        watchdog.disarm()
        trace("\(name): watchdog disarmed")
    }
    do { try await body() } catch {
        trace("\(name): body threw \(error)")
        throw error
    }
    // Everything the body created has been released by here.
    trace("\(name): body returned")
}

/// Starts a proxy and arranges for its cleanup, with trace lines at the edges
/// of the `defer`. The cleanup runs `Process.waitUntilExit()` on the main
/// actor; that call is kept as it is while its cause is under investigation.
@MainActor
private func withProxy(_ name: String, _ body: @MainActor (BrokerProxy) async throws -> Void) async throws {
    let proxy = try await BrokerProxy.launch()
    defer {
        trace("\(name): defer begin (proxy cleanup)")
        proxy.terminate()
        trace("\(name): defer end (proxy cleanup)")
    }
    try await body(proxy)
}

@MainActor
private func tracedManager(port: UInt16) throws -> CommunicationManager {
    let manager = try makeManager(port: port)
    manager.traceForTesting = { trace($0) }
    return manager
}

@MainActor
private func scenarioJoinsAttemptResumingAfterStop() async throws {
    let name = "joinsAttemptResumingAfterStop"
    try await watched(name) {
        try await withProxy(name) { proxy in
            let manager = try tracedManager(port: proxy.port)
            let attempt = AttemptProbe()
            manager.reconnectAttempt = { controls in
                attempt.begin(controls)
                // Like Axoloty's `reconnect()`: ignore cancellation, then open
                // the transport whatever happened in the meantime.
                await attempt.gate.wait()
                await controls.openTransport()
                attempt.end()
            }
            try await start(manager)
            proxy.switchToBlackhole()
            try await poll("reconnect attempt began") { attempt.began }

            // Shutdown starts while the attempt is suspended. Release the attempt
            // only once the runtime has finished stopping: the window in which
            // Axoloty's attempt resumes and reaches `transport.start()`.
            let stopper = Task { @MainActor in
                await manager.stopAndWait()
                return attempt.active
            }
            try await poll("runtime stopped") { await attempt.runtimeStopped() }
            trace("\(name): opening the gate")
            await attempt.gate.open()
            let activeAtReturn = try await within("stopAndWait") { await stopper.value }
            trace("\(name): stopAndWait returned")

            #expect(!activeAtReturn, "stopAndWait() returned while a reconnect attempt was active")
            // Anything the late attempt opened must already be closed.
            try await poll("no broker connection left open", timeout: .seconds(3)) { proxy.counts()?.open == 0 }
            try await expectQuiet(proxy, for: .seconds(1))
        }
    }
}

@MainActor
private func scenarioAttemptNeverReturns() async throws {
    let name = "attemptNeverReturns"
    try await watched(name) {
        try await withProxy(name) { proxy in
            let manager = try tracedManager(port: proxy.port)
            manager.reconnectSettleTimeout = .milliseconds(300)
            let attempt = AttemptProbe()
            manager.reconnectAttempt = { controls in
                attempt.begin(controls)
                await attempt.gate.wait()   // never opened while the test asserts
                await controls.openTransport()
                attempt.end()
            }
            try await start(manager)
            proxy.switchToBlackhole()
            try await poll("reconnect attempt began") { attempt.began }

            let started = ContinuousClock.now
            try await within("stopAndWait", .seconds(10)) { await manager.stopAndWait() }
            trace("\(name): stopAndWait returned")
            #expect(ContinuousClock.now - started < .seconds(3), "Shutdown waited past its bound")
            #expect(attempt.active, "The attempt should still be suspended at the bound")

            // Release it. The late attempt closes the transport it opens.
            trace("\(name): opening the gate")
            await attempt.gate.open()
            trace("\(name): gate opened")
            try await poll("late attempt returned", timeout: .seconds(3)) { !attempt.active }
            trace("\(name): late attempt returned")
            try await poll("late transport closed", timeout: .seconds(3)) { proxy.counts()?.open == 0 }
            trace("\(name): late transport closed")
            try await expectQuiet(proxy, for: .seconds(1))
            trace("\(name): quiet")
        }
    }
}

@MainActor
private func scenarioTeardownNeverReturns() async throws {
    let name = "teardownNeverReturns"
    try await watched(name) {
        try await withProxy(name) { proxy in
            let manager = try tracedManager(port: proxy.port)
            manager.shutdownTimeout = .milliseconds(500)
            let stuck = Gate()
            // Stands in for an Axoloty or MQTT call that never returns.
            manager.drainHookForTesting = { await stuck.wait() }
            try await start(manager)

            let started = ContinuousClock.now
            try await within("stopAndWait", .seconds(10)) { await manager.stopAndWait() }
            trace("\(name): stopAndWait returned")
            #expect(ContinuousClock.now - started < .seconds(3), "stopAndWait() was not bounded")
            await stuck.open()
        }
    }
}

@MainActor
private func scenarioHandshakeStall() async throws {
    let name = "handshakeStall"
    try await watched(name) {
        try await withProxy(name) { proxy in
            let manager = try tracedManager(port: proxy.port)
            try await start(manager)
            proxy.switchToBlackhole()
            // The first reconnect connects a socket that never answers CONNACK.
            try await poll("reconnect handshake suspended") {
                guard let counts = proxy.counts() else { return false }
                return counts.accepted >= 2 && counts.open >= 1
            }

            let started = ContinuousClock.now
            try await within("stopAndWait", .seconds(10)) { await manager.stopAndWait() }
            trace("\(name): stopAndWait returned")
            #expect(ContinuousClock.now - started < .seconds(3), "Shutdown did not promptly unblock the MQTT handshake")
            try await poll("no broker connection left open", timeout: .seconds(3)) { proxy.counts()?.open == 0 }
            try await expectQuiet(proxy, for: .seconds(2))
        }
    }
}

// MARK: - Helpers

@MainActor
private func makeManager(port: UInt16) throws -> CommunicationManager {
    try CommunicationManager(
        identity: Identity(name: "reconnect-test"),
        communicationOptions: .init(namespace: "reconnect-\(UUID().uuidString)", mqttClientOptions: .init(host: "127.0.0.1", port: port)),
        commonOptions: nil
    )
}

@MainActor
private func start(_ manager: CommunicationManager) async throws {
    let started = try await within("manager start") { (try? await manager.startAndWaitUntilReady()) != nil }
    try #require(started, "The manager did not start")
}

/// Runs `operation` and fails the test, instead of hanging it, when the
/// operation does not finish in time. Swift Testing cannot kill a hung
/// test, so no test body may wait on the product without this.
private func within<Value: Sendable>(
    _ what: String,
    _ timeout: Duration = .seconds(15),
    _ operation: @escaping @Sendable () async -> Value
) async throws -> Value {
    guard let value = await BoundedWait.run(timeout: timeout, operation) else {
        trace("TIMED OUT waiting for: \(what)")
        Issue.record("Timed out after \(timeout) waiting for: \(what)")
        throw TestHang(what: what)
    }
    return value
}

/// Fails unless `condition` holds within the bound. Polls; never sleeps for a fixed time.
/// Each evaluation is itself bounded, because the condition can call into the product.
private func poll(_ what: String, timeout: Duration = .seconds(15), _ condition: @escaping @Sendable @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero,
              let holds = await BoundedWait.run(timeout: remaining, { await condition() }) else {
            trace("TIMED OUT waiting for: \(what)")
            Issue.record("Timed out waiting for: \(what)")
            throw TestHang(what: what)
        }
        if holds { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Asserts that the proxy accepts no new connection for the whole window.
private func expectQuiet(_ proxy: BrokerProxy, for window: Duration) async throws {
    let accepted = try #require(proxy.counts(), "Proxy counts unreadable").accepted
    let until = ContinuousClock.now + window
    while ContinuousClock.now < until {
        let counts = try #require(proxy.counts(), "Proxy counts unreadable")
        #expect(counts.accepted == accepted, "A reconnect opened a socket after shutdown: \(counts)")
        #expect(counts.open == 0, "A connection was open after shutdown: \(counts)")
        try await Task.sleep(for: .milliseconds(20))
    }
}

private struct TestHang: Error { let what: String }

/// The time budgets behind the watchdog, in seconds.
///
/// The watchdog has to fire before Swift Testing's per-test limit, leave room
/// for its own report, and still stay clear of a slow but successful run.
/// The worst successful path is the sum of generous ceilings for each stage
/// of the slowest scenario. macOS CI finished that scenario in 2.9 s.
private enum Budget {
    /// `.timeLimit(.minutes(1))` on each test.
    static let testLimit = 60.0
    /// How long the diagnostic subprocess may run. `sample` samples for 2 s.
    static let sampleWait = 6.0
    /// After the wait: time for the subprocess to die when asked, then to be killed.
    static let killGrace = 1.0
    /// After the subprocess ends: time for the reader to reach end of file.
    static let drainGrace = 1.0
    /// The most the dump takes: 6 + 1 + 1 = 8.
    static var sampleHardBound: Double { sampleWait + killGrace + drainGrace }
    /// Printing the trace lines and the sample output.
    static let printAllowance = 1.0
    /// Time from watchdog expiry to the process ending.
    static var diagnostics: Double { sampleHardBound + printAllowance }
    /// Thread wake-up and scheduling delay on a loaded runner.
    static let schedulingMargin = 3.0
    /// When the watchdog fires, counted from the start of a scenario: 60 - 9 - 3 = 48.
    static var watchdog: Double { testLimit - diagnostics - schedulingMargin }

    /// Ceilings for each stage of a successful run of the slowest scenario.
    static let stages: [(name: String, seconds: Double)] = [
        ("proxy launch (start node, wait for the port file)", 3),
        ("manager start", 5),
        ("reconnect attempt begins (250 ms backoff)", 2),
        ("runtime stopped", 3),
        ("stopAndWait (1 s linger and the teardown)", 7),
        ("late connection closes", 1),
        ("quiet window", 2),
        ("proxy cleanup (SIGKILL and waitUntilExit)", 2),
    ]
    /// 3 + 5 + 2 + 3 + 7 + 1 + 2 + 2 = 25.
    static var worstSuccessfulPath: Double { stages.reduce(0) { $0 + $1.seconds } }
}

private final class TraceLog: @unchecked Sendable { // SAFETY: `lines` is only read or written while holding the lock.
    static let shared = TraceLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let start = Date()

    func record(_ message: String) -> String {
        let elapsed = Date().timeIntervalSince(start)
        let thread = Thread.isMainThread ? "main" : "other"
        let line = String(format: "TRACE %9.3f [%@] %@", elapsed, thread, message)
        lock.withLock {
            lines.append(line)
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        }
        return line
    }

    func recent(_ count: Int) -> [String] { lock.withLock { Array(lines.suffix(count)) } }
}

/// Prints a progress line, and keeps it for the watchdog report, so a CI log
/// shows where a stalled test stopped.
private func trace(_ message: String) {
    print(TraceLog.shared.record(message))
    fflush(nil)
}

/// Ends the process, with diagnostics, when a test does not finish in time.
///
/// Swift Testing cannot kill a hung test, and a stalled run holds the CI job
/// until the harness timeout. The watchdog runs on its own thread, not on the
/// Swift cooperative pool or the main actor, so a blocked pool cannot stop it.
private final class Watchdog: @unchecked Sendable { // SAFETY: the only state is a semaphore, which is thread safe.
    private let finished = DispatchSemaphore(value: 0)

    static func arm(_ name: String, seconds: Double, onExpiry: (@Sendable (String) -> Void)? = nil) -> Watchdog {
        let watchdog = Watchdog()
        let thread = Thread {
            guard watchdog.finished.wait(timeout: .now() + seconds) == .timedOut else { return }
            if let onExpiry { onExpiry(name) } else { terminate(name, seconds: seconds) }
        }
        thread.name = "watchdog-\(name)"
        thread.start()
        return watchdog
    }

    func disarm() { finished.signal() }

    /// The text printed on expiry before the thread dump: the last trace line
    /// and the lines before it.
    static func report(_ name: String, seconds: Double = Budget.watchdog) -> String {
        let recent = TraceLog.shared.recent(40)
        return """
        WATCHDOG: test \(name) did not finish in time (budget \(seconds) s)
        LAST TRACE: \(recent.last ?? "none")
        RECENT TRACE:
        \(recent.joined(separator: "\n"))
        """
    }

    private static func terminate(_ name: String, seconds: Double) {
        print(report(name, seconds: seconds))
        fflush(nil)
        print("WATCHDOG: thread dump follows")
        fflush(nil)
        dumpThreads()
        print("WATCHDOG: ending the process")
        fflush(nil)
        _exit(70)
    }

    /// Prints every thread's stack with the platform's sampler, when there is one.
    private static func dumpThreads() {
        let pid = String(getpid())
        #if os(Linux)
        let command = ["/usr/bin/env", "gdb", "-p", pid, "-batch", "-ex", "thread apply all bt 25"]
        #else
        let command = ["/usr/bin/sample", pid, "2"]
        #endif
        let outcome = runBounded(command, bound: Budget.sampleWait)
        if outcome.timedOut { print("WATCHDOG: \(command[0]) did not finish within \(Budget.sampleWait) s and was killed; partial output follows") }
        print(outcome.output.split(separator: "\n", omittingEmptySubsequences: false).prefix(600).joined(separator: "\n"))
    }

    /// Runs a subprocess and returns its output. It waits `bound` seconds for
    /// the subprocess, then asks it to stop, then kills it. Total time is at
    /// most `bound + Budget.killGrace + Budget.drainGrace`. Every wait is a
    /// semaphore with a timeout, never an unbounded read or `waitUntilExit`.
    static func runBounded(_ command: [String], bound: Double) -> (output: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputBuffer()
        let endOfFile = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                endOfFile.signal()
            } else {
                collected.append(chunk)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ("could not run \(command[0]): \(error)", false)
        }
        // The parent's copy of the write end must close, or the reader never sees end of file.
        try? pipe.fileHandleForWriting.close()
        var timedOut = false
        if exited.wait(timeout: .now() + bound) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + Budget.killGrace) == .timedOut { _ = kill(process.processIdentifier, SIGKILL) }
        }
        _ = endOfFile.wait(timeout: .now() + Budget.drainGrace)
        pipe.fileHandleForReading.readabilityHandler = nil
        return (collected.text, timedOut)
    }
}

private final class OutputBuffer: @unchecked Sendable { // SAFETY: `data` is only read or written while holding the lock.
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Holds an object weakly, to observe that it is released.
private final class WeakBox: @unchecked Sendable { // SAFETY: `object` is only read or written while holding the lock.
    private let lock = NSLock()
    private weak var object: AnyObject?

    func observe(_ value: AnyObject) { lock.withLock { object = value } }
    private var isNil: Bool { lock.withLock { object == nil } }

    /// Polls for release, bounded.
    func isReleased(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isNil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isNil
    }
}

/// Records one stand-in reconnect attempt.
@MainActor
private final class AttemptProbe {
    let gate = Gate()
    private(set) var began = false
    private(set) var active = false
    private var runtimeHasStopped: (@MainActor () async -> Bool)?

    func begin(_ controls: CommunicationManager.ReconnectAttemptControls) {
        began = true; active = true; runtimeHasStopped = controls.runtimeHasStopped
    }
    func end() { active = false }
    func runtimeStopped() async -> Bool { await runtimeHasStopped?() ?? false }
}

/// A latch the stand-in attempt waits on. It deliberately ignores cancellation.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A TCP proxy in front of the container's broker. After `switchToBlackhole()`
/// it drops every connection and then accepts new ones without answering.
private final class BrokerProxy: @unchecked Sendable {
    struct Counts: CustomStringConvertible {
        var accepted: Int
        var closed: Int
        var open: Int { accepted - closed }
        var description: String { "accepted \(accepted), closed \(closed)" }
    }

    let port: UInt16
    private let directory: URL
    private let process: Process

    private init(port: UInt16, directory: URL, process: Process) {
        self.port = port; self.directory = directory; self.process = process
    }

    static func launch() async throws -> BrokerProxy {
        trace("proxy: launch begin")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reconnect-proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReconnectProxy/proxy.cjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, directory.path]
        try process.run()
        trace("proxy: node started, pid \(process.processIdentifier)")
        let portFile = directory.appendingPathComponent("port")
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: portFile.path) {
            guard ContinuousClock.now < deadline else {
                _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                throw ProxyError.didNotStart
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let port = UInt16((try String(contentsOf: portFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            throw ProxyError.didNotStart
        }
        trace("proxy: ready on port \(port)")
        return BrokerProxy(port: port, directory: directory, process: process)
    }

    func switchToBlackhole() {
        try? "yes".write(to: directory.appendingPathComponent("blackhole"), atomically: true, encoding: .utf8)
    }

    func counts() -> Counts? {
        let values = ((try? String(contentsOf: directory.appendingPathComponent("counts"), encoding: .utf8)) ?? "")
            .split(separator: " ").compactMap { Int($0) }
        guard values.count == 2 else { return nil }
        return Counts(accepted: values[0], closed: values[1])
    }

    func terminate() {
        trace("proxy: terminate begin (running \(process.isRunning))")
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            trace("proxy: SIGKILL sent; waitUntilExit begin")
            process.waitUntilExit()
            trace("proxy: waitUntilExit end")
        }
        try? FileManager.default.removeItem(at: directory)
        trace("proxy: terminate end (directory removed)")
    }

    enum ProxyError: Error { case didNotStart }
}
