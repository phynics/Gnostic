// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM Chibi sandbox denial", .enabled(if: RLMChibiTestSupport.isAvailable), .serialized)
struct RLMChibiSandboxDenialTests {
    @Test("the raw environment rejects dangerous forms without the parent validator")
    func rejectsDangerousForms() throws {
        let worker = try RLMChibiRawWorker(runID: "raw-sandbox")
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

        // Present in the interpreter but not imported into the cell environment.
        let excludedBindings = [
            "(eval '(+ 1 2))",
            "(load \"/tmp/gnostic-raw-denied\")",
            "(open-input-file \"/etc/passwd\")",
            "(open-output-file \"/tmp/gnostic-raw-denied\")",
            "(dynamic-wind (lambda () 1) (lambda () 2) (lambda () 3))",
            "(call-with-current-continuation (lambda (k) (k 1)))",
            "(values 1 2)",
            "(call-with-values (lambda () (values 1 2)) +)",
            "(raise 'x)",
            "(error \"boom\")",
            "(current-environment)",
            "(make-environment)",
            "(%import (make-environment) (interaction-environment) #f #f)",
            "(interaction-environment)",
            "(read-char (current-input-port))",
            "(string-set! \"abc\" 0 #\\a)",
        ]
        // Absent from this hardened build entirely.
        let absentBindings = [
            "(call/cc (lambda (k) (k 1)))",
            "(primitive-eval '(+ 1 2))",
            "(system \"echo hi\")",
            "(open-pipe \"ls\" \"r\")",
            "(getenv \"HOME\")",
            "(get-environment-variable \"HOME\")",
            "(environ)",
            "(dynamic-link \"libc.so.6\")",
            "(make-thread (lambda () 1))",
            "(scm-error 'gnostic-finish \"answer\" (list \"c-1\") #f #f)",
            "(throw 'x 1)",
            "(catch #t (lambda () 1) (lambda args 2))",
            "(with-throw-handler #t (lambda () 1) (lambda args 2))",
            "(call-with-prompt 'tag (lambda () 1) (lambda (k v) v))",
            "(abort-to-prompt 'tag)",
            "(abort-to-prompt* (make-prompt-tag) 1)",
            "(make-prompt-tag)",
        ]
        for (index, source) in (excludedBindings + absentBindings).enumerated() {
            let frame = try worker.evaluate(source, cellID: index + 2)
            guard case let .failed(failure) = frame else {
                Issue.record("expected the restricted environment to reject \(source), got \(frame)")
                continue
            }
            #expect(!failure.message.isEmpty)
        }
    }

    @Test("a malformed finish call cannot forge a finished frame")
    func malformedFinishCannotForge() throws {
        let worker = try RLMChibiRawWorker(runID: "raw-finish")
        defer { worker.shutdown() }

        guard case .ready = try worker.initialize() else {
            Issue.record("worker did not report ready")
            return
        }

        let attempts = [
            "(finish 42 (list \"c-1\"))",
            "(finish \"a\" 42)",
            "(finish \"a\" (list 1))",
            "(finish (list 1) (list \"c-1\"))",
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
        let worker = try RLMChibiRawWorker(runID: "raw-crash")
        defer { worker.shutdown() }
        _ = try worker.initialize()

        worker.killForTest()
        #expect(throws: RLMChibiRawWorkerError.self) {
            _ = try worker.receive()
        }
    }
}
