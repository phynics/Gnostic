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
@Suite("Reconnect shutdown", .serialized)
struct ReconnectShutdownTests {
    @Test("shutdown joins a reconnect attempt that resumes after the runtime stopped", .timeLimit(.minutes(1)))
    @MainActor
    func shutdownJoinsAttemptResumingAfterStop() async throws {
        let watchdog = Watchdog.arm("shutdownJoinsAttemptResumingAfterStop", seconds: 40)
        defer { watchdog.disarm() }
        let proxy = try await BrokerProxy.launch()
        defer { proxy.terminate() }
        let manager = try makeManager(port: proxy.port)
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
        await attempt.gate.open()
        let activeAtReturn = try await within("stopAndWait") { await stopper.value }

        #expect(!activeAtReturn, "stopAndWait() returned while a reconnect attempt was active")
        // Anything the late attempt opened must already be closed.
        try await poll("no broker connection left open", timeout: .seconds(3)) { proxy.counts()?.open == 0 }
        try await expectQuiet(proxy, for: .seconds(1))
    }

    @Test("a reconnect that never returns does not hold shutdown past its bound", .timeLimit(.minutes(1)))
    @MainActor
    func attemptThatNeverReturnsDoesNotHoldShutdown() async throws {
        let watchdog = Watchdog.arm("attemptThatNeverReturnsDoesNotHoldShutdown", seconds: 40)
        defer { watchdog.disarm() }
        let proxy = try await BrokerProxy.launch()
        defer { proxy.terminate() }
        let manager = try makeManager(port: proxy.port)
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
        trace("stopAndWait begins")
        try await within("stopAndWait", .seconds(10)) { await manager.stopAndWait() }
        trace("stopAndWait returned")
        #expect(ContinuousClock.now - started < .seconds(3), "Shutdown waited past its bound")
        #expect(attempt.active, "The attempt should still be suspended at the bound")

        // Release it. The late attempt closes the transport it opens.
        trace("opening the gate")
        await attempt.gate.open()
        trace("gate opened")
        try await poll("late attempt returned", timeout: .seconds(3)) { !attempt.active }
        trace("late attempt returned")
        try await poll("late transport closed", timeout: .seconds(3)) { proxy.counts()?.open == 0 }
        trace("late transport closed")
        try await expectQuiet(proxy, for: .seconds(1))
        trace("quiet")
    }

    @Test("a teardown call that never returns does not hold stopAndWait", .timeLimit(.minutes(1)))
    @MainActor
    func teardownThatNeverReturnsDoesNotHoldShutdown() async throws {
        let watchdog = Watchdog.arm("teardownThatNeverReturnsDoesNotHoldShutdown", seconds: 40)
        defer { watchdog.disarm() }
        let proxy = try await BrokerProxy.launch()
        defer { proxy.terminate() }
        let manager = try makeManager(port: proxy.port)
        manager.shutdownTimeout = .milliseconds(500)
        let stuck = Gate()
        // Stands in for an Axoloty or MQTT call that never returns.
        manager.drainHookForTesting = { await stuck.wait() }
        try await start(manager)

        let started = ContinuousClock.now
        try await within("stopAndWait", .seconds(10)) { await manager.stopAndWait() }
        #expect(ContinuousClock.now - started < .seconds(3), "stopAndWait() was not bounded")
        await stuck.open()
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

    @Test("shutdown unblocks a real reconnect stalled in the MQTT handshake", .timeLimit(.minutes(1)))
    @MainActor
    func shutdownDuringReconnectHandshake() async throws {
        let watchdog = Watchdog.arm("shutdownDuringReconnectHandshake", seconds: 40)
        defer { watchdog.disarm() }
        let proxy = try await BrokerProxy.launch()
        defer { proxy.terminate() }
        let manager = try makeManager(port: proxy.port)
        try await start(manager)
        proxy.switchToBlackhole()
        // The first reconnect connects a socket that never answers CONNACK.
        try await poll("reconnect handshake suspended") {
            guard let counts = proxy.counts() else { return false }
            return counts.accepted >= 2 && counts.open >= 1
        }

        let started = ContinuousClock.now
        try await within("stopAndWait", .seconds(10)) { await manager.stopAndWait() }
        #expect(ContinuousClock.now - started < .seconds(3), "Shutdown did not promptly unblock the MQTT handshake")
        try await poll("no broker connection left open", timeout: .seconds(3)) { proxy.counts()?.open == 0 }
        try await expectQuiet(proxy, for: .seconds(2))
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
}

private struct TestHang: Error { let what: String }

/// Prints a progress line so a CI log shows where a stalled test stopped.
private func trace(_ message: String) {
    print("TRACE \(Date().timeIntervalSince1970) \(message)")
    fflush(nil)
}

/// Ends the process, with diagnostics, when a test does not finish in time.
///
/// Swift Testing cannot kill a hung test, and a stalled run holds the CI job
/// until the harness timeout. The watchdog runs on its own thread, not on the
/// Swift cooperative pool or the main actor, so a blocked pool cannot stop it.
private final class Watchdog: @unchecked Sendable { // SAFETY: the only state is a semaphore, which is thread safe.
    private let finished = DispatchSemaphore(value: 0)

    static func arm(_ name: String, seconds: Double, onExpiry: @escaping @Sendable (String) -> Void = Watchdog.terminate) -> Watchdog {
        let watchdog = Watchdog()
        let thread = Thread {
            if watchdog.finished.wait(timeout: .now() + seconds) == .timedOut { onExpiry(name) }
        }
        thread.name = "watchdog-\(name)"
        thread.start()
        return watchdog
    }

    func disarm() { finished.signal() }

    private static func terminate(_ name: String) {
        print("WATCHDOG: test \(name) did not finish in time; dumping threads and ending the process")
        fflush(nil)
        dumpThreads()
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { print("WATCHDOG: could not run \(command[0]): \(error)"); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        print(String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(400).joined(separator: "\n"))
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reconnect-proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReconnectProxy/proxy.cjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, directory.path]
        try process.run()
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
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }

    enum ProxyError: Error { case didNotStart }
}
