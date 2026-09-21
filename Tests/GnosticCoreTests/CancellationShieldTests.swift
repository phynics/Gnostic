// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCore

@Suite("Cancellation shield")
struct CancellationShieldTests {
    /// Releases exactly once and never blocks a second waiter, so a failing
    /// shield fails the expectation instead of hanging the run.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let resumed = waiters
            waiters.removeAll()
            for waiter in resumed { waiter.resume() }
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor IsolationProbe {
        var steps = 0

        /// Mutating isolated state across a suspension inside the shielded body
        /// only holds if the body runs in this actor's isolation.
        func runShielded() async -> Bool {
            await withUnstructuredCancellationShield {
                self.steps += 1
                await Task.yield()
                self.steps += 1
                return self === #isolation && self.steps == 2
            }
        }
    }

    @Test("the fallback shield hides mid-flight cancellation from the body")
    func fallbackHidesMidFlightCancellation() async {
        let started = Gate()
        let release = Gate()
        let shielded = Task { () -> Bool in
            await withUnstructuredCancellationShield {
                await started.open()
                await release.wait()
                return !Task.isCancelled
            }
        }

        await started.wait()
        shielded.cancel()
        await release.open()

        #expect(await shielded.value, "the shielded body observed its caller's cancellation")
    }

    @Test("the fallback shield runs a body whose caller is cancelled before it starts")
    func fallbackRunsAfterEarlyCancellation() async {
        let start = Gate()
        let shielded = Task { () -> Bool in
            await start.wait() // hold the task until the test has cancelled it
            return await withUnstructuredCancellationShield {
                await Task.yield()
                return !Task.isCancelled
            }
        }

        shielded.cancel()
        await start.open()

        #expect(await shielded.value, "the shielded body observed its caller's cancellation")
    }

    @Test("the fallback shield runs the body in the caller's isolation")
    func fallbackPreservesCallerIsolation() async {
        #expect(await IsolationProbe().runShielded(), "the shielded body left the caller's actor")
    }

    @Test("the shield entry point hides cancellation on this platform's path")
    func entryPointHidesCancellation() async {
        let started = Gate()
        let release = Gate()
        let shielded = Task { () -> Bool in
            await withCancellationShield {
                await started.open()
                await release.wait()
                return !Task.isCancelled
            }
        }

        await started.wait()
        shielded.cancel()
        await release.open()

        #expect(await shielded.value, "the shielded body observed its caller's cancellation")
    }

    @Test("no source emits the 27-only cancellation shield")
    func sourcesDoNotReferenceTheShieldedPrimitive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        for path in paths {
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            #expect(
                !source.contains("withTaskCancellationShield("),
                "Sources/\(path) references the 27-only shield; its always-emitted body would leave a load-time dependency on the 27 runtime"
            )
        }

        let wrapper = "Sources/GnosticCore/Concurrency/CancellationShield.swift"
        let wrapperSource = try String(contentsOf: root.appendingPathComponent(wrapper), encoding: .utf8)
        #expect(
            !wrapperSource.contains("#available(anyAppleOS 27.0, *)"),
            "the wrapper must not gate the 27-only shield behind an availability check; the reference is load-time"
        )
    }
}
