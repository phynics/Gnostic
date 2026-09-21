// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM Guile sandbox denial", .enabled(if: RLMGuileTestSupport.isAvailable), .serialized)
struct RLMGuileSandboxDenialTests {
    @Test("the raw sandbox rejects dangerous forms without the parent validator")
    func rejectsDangerousForms() throws {
        let worker = try RLMGuileRawWorker(runID: "raw-sandbox")
        defer { worker.shutdown() }

        guard case .ready = try worker.initialize() else {
            Issue.record("worker did not report ready")
            return
        }

        let control = try worker.evaluate("(+ 1 2)", cellID: 1)
        #expect(control == .evaluated(RLMSchemeEvaluated(
            runID: "raw-sandbox",
            cellID: 1,
            value: .integer(3),
            output: ""
        )))

        let denied = [
            "(eval '(+ 1 2))",
            "(primitive-eval '(+ 1 2))",
            "(system \"echo hi\")",
            "(open-pipe \"ls\" \"r\")",
            "(getenv \"HOME\")",
            "(open-input-file \"/etc/passwd\")",
            "(open-output-file \"/tmp/gnostic-raw-denied\")",
            "(dynamic-wind (lambda () 1) (lambda () 2) (lambda () 3))",
            "(call/cc (lambda (k) (k 1)))",
            "(dynamic-link \"libc.so.6\")",
            "(make-thread (lambda () 1))",
            "(throw 'x 1)",
            "(catch #t (lambda () 1) (lambda args 2))",
            "(values 1 2)",
            "(call-with-values (lambda () (values 1 2)) +)",
            "(call-with-prompt 'tag (lambda () 1) (lambda (k v) v))",
            "(abort-to-prompt 'tag)",
        ]
        for (index, source) in denied.enumerated() {
            let frame = try worker.evaluate(source, cellID: index + 2)
            guard case let .failed(failure) = frame else {
                Issue.record("expected the sandbox to reject \(source), got \(frame)")
                continue
            }
            #expect(!failure.message.isEmpty)
        }
    }

    @Test("a raw throw cannot forge a finished frame")
    func throwBypassYieldsFailedFrame() throws {
        let worker = try RLMGuileRawWorker(runID: "raw-throw")
        defer { worker.shutdown() }

        guard case .ready = try worker.initialize() else {
            Issue.record("worker did not report ready")
            return
        }

        let attempts = [
            "(throw 'gnostic-finish 42 \"x\")",
            "(throw 'gnostic-finish \"a\")",
        ]
        for (index, source) in attempts.enumerated() {
            let frame = try worker.evaluate(source, cellID: index + 1)
            guard case let .failed(failure) = frame else {
                Issue.record("expected a failed frame for \(source), got \(frame)")
                continue
            }
            #expect(!failure.message.isEmpty)
        }
    }

    @Test("a killed worker surfaces EOF instead of hanging")
    func killedWorkerSurfacesEOF() throws {
        let worker = try RLMGuileRawWorker(runID: "raw-crash")
        defer { worker.shutdown() }
        _ = try worker.initialize()

        worker.killForTest()
        #expect(throws: RLMGuileRawWorkerError.self) {
            _ = try worker.receive()
        }
    }
}
