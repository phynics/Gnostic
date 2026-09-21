// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM
import GnosticRLMGuile

@Suite("RLM Guile worker session", .enabled(if: RLMGuileTestSupport.isAvailable), .serialized)
struct RLMGuileWorkerSessionTests {
    @Test("accepted fixtures execute with invocation-local state across root iterations")
    func invocationLocalState() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()
        #expect(await session.isRunning)

        let first = await session.evaluate(source: "(define findings (corpus-search \"retirement\" 4))")
        #expect(first == .value(.list([])))

        let second = await session.evaluate(source: "(list (length findings) (cdr (assq 'chunk-id (car findings))))")
        #expect(second == .value(.list([.integer(1), .string("c-1")])))

        let third = await session.evaluate(source: "(finish (string-append \"answer\" \"!\") (list \"c-1\"))")
        #expect(third == .finished(answer: "answer!", evidenceIDs: ["c-1"]))

        let recorded = await host.recorded()
        #expect(recorded.contains(.corpusSearch(query: "retirement", limit: 4)))

        await session.shutdown()
    }

    @Test("disallowed cells are rejected in the parent before evaluation")
    func rejectsBeforeEvaluation() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let rejected = await session.evaluate(source: "(system \"sh\")")
        #expect(rejected == .cellRejected("disallowed symbol 'system'"))
        #expect(await session.isRunning)

        let accepted = await session.evaluate(source: "(+ 1 2)")
        #expect(accepted == .value(.integer(3)))
        #expect(await host.recorded().isEmpty)

        await session.shutdown()
    }

    @Test("only bounded corpus, model, progress, and finish calls are serviced")
    func boundedHostCalls() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: """
        (let* (
            (hits (corpus-search "q" 2))
            (chunks (corpus-read-many (list "c-1")))
            (answers (lm-query-batched (list "p1" "p2") 'fast))
            (single (lm-query "p3" 'primary))
            (utility (lm-query "p4" 'utility)))
          (progress "done")
          (finish (string-join answers ",") (list "c-1")))
        """)
        #expect(outcome == .finished(answer: "leaf:p1,leaf:p2", evidenceIDs: ["c-1"]))

        let recorded = await host.recorded()
        #expect(recorded.count == 6)
        #expect(recorded.contains(.corpusRead(chunkIDs: ["c-1"])))
        #expect(recorded.contains(.leafQuery(prompts: ["p1", "p2"], tier: .fast)))
        #expect(recorded.contains(.leafQuery(prompts: ["p3"], tier: .primary)))
        #expect(recorded.contains(.leafQuery(prompts: ["p4"], tier: .utility)))
        #expect(recorded.contains(.progress("done")))

        await session.shutdown()
    }

    @Test("a non-literal host argument becomes a structured scheme failure")
    func nonLiteralHostArgumentFailsStructurally() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(corpus-search (lambda () 1) 2)")
        guard case let .schemeFailed(message) = outcome else {
            Issue.record("expected a structured scheme failure, got \(outcome)")
            return
        }
        #expect(message.contains("host call failed"))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("wire conversion keeps control strings decodable")
    func controlStringIsDecodable() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(corpus-search \"a\\x08;\" 2)")
        #expect(await host.recorded().contains(.corpusSearch(query: "a?;", limit: 2)))
        guard case .value = outcome else {
            Issue.record("expected a decoded host result, got \(outcome)")
            return
        }
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("wire conversion keeps bar-quoted symbols decodable")
    func specialSymbolIsDecodable() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(list (string->symbol \"1\") (string->symbol \"-1\") (string->symbol \"+1\") (string->symbol \".\") (string->symbol \".0\") (string->symbol \"[\"))")
        #expect(outcome == .value(.list(Array(repeating: .character("~"), count: 6))))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("wire symbols use the documented ASCII identifier rule")
    func unicodeSymbolsUsePlaceholder() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let source = #"(list (string->symbol "A") (string->symbol "z9") (string->symbol "a-b") (string->symbol "\xE9;") (string->symbol "\x3A9;") (string->symbol "caf\xE9;") (string->symbol "A_"))"#
        let outcome = await session.evaluate(source: source)
        #expect(outcome == .value(.list([
            .symbol("A"), .symbol("z9"), .symbol("a-b"),
            .character("~"), .character("~"), .character("~"), .character("~"),
        ])))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("real symbols cannot collide with wire placeholder sentinels")
    func sentinelNameDoesNotCollide() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(list (string->symbol \"gnostic-symbol\") (string->symbol \"gnostic-unsupported\") (string->symbol \"gnostic-truncated\"))")
        #expect(outcome == .value(.list([
            .symbol("gnostic-symbol"),
            .symbol("gnostic-unsupported"),
            .symbol("gnostic-truncated"),
        ])))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("ready metadata sanitizes control characters before framing")
    func readyMetadataIsWireSafe() throws {
        var environment = RLMGuileWorkerConfiguration.scrubbedEnvironment
        environment["A\u{8}B"] = "value"
        let worker = try RLMGuileRawWorker(runID: "run\u{8}id", environment: environment)
        defer { worker.shutdown() }

        guard case let .ready(ready) = try worker.initialize() else {
            Issue.record("worker did not report ready")
            return
        }
        #expect(ready.runID == "run?id")
        #expect(ready.environmentKeys.contains("A?B"))
    }

    @Test("finish answer with a control character remains structured")
    func finishControlStringIsDecodable() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(finish (string-append \"a\" \"\\x08;\") (list \"c-1\"))")
        #expect(outcome == .finished(answer: "a?;", evidenceIDs: ["c-1"]))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("wire conversion preserves parser-supported string escapes")
    func newlineStringIsPreserved() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(string-append \"line1\" \"\\n\" \"line2\\t tabbed\")")
        #expect(outcome == .value(.string("line1\nline2\t tabbed")))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("wire conversion replaces non printable and non ASCII strings")
    func nonPrintableStringsAreReplaced() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(corpus-search \"a\\x01;\\x0e;\\xa0;\\xad;b\" 2)")
        #expect(await host.recorded().contains(.corpusSearch(query: "a?;?;?;?;b", limit: 2)))
        guard case .value = outcome else {
            Issue.record("expected a decoded host result, got \(outcome)")
            return
        }
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("host failures with control characters remain structured")
    func controlCharacterHostFailureIsStructured() async throws {
        let host = RLMGuileRecordingHost(leafFailure: .leafModelFailed("provider \u{8} failed"))
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(lm-query \"prompt\")")
        guard case let .schemeFailed(message) = outcome else {
            Issue.record("expected a structured host failure, got \(outcome)")
            return
        }
        #expect(message.contains("host call failed"))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("long valid host strings remain serviced")
    func longHostStringIsPreserved() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let query = String(repeating: "a", count: 5_000)
        let outcome = await session.evaluate(source: "(corpus-search \"\(query)\" 2)")
        if case .protocolViolation = outcome {
            Issue.record("long host string caused a protocol violation")
        }
        #expect(await host.recorded().contains(.corpusSearch(query: query, limit: 2)))
        #expect(await session.isRunning)

        await session.shutdown()
    }

    @Test("infinite evaluation is bounded and the worker survives")
    func infiniteEvaluationIsBounded() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let spin = await session.evaluate(source: "(define (spin n) (spin n)) (spin 0)")
        #expect(spin == .schemeFailed("resource limit exceeded"))
        #expect(await session.isRunning)

        let recovered = await session.evaluate(source: "(+ 1 2)")
        #expect(recovered == .value(.integer(3)))

        await session.shutdown()
    }

    @Test("the parent wall deadline terminates a stuck worker")
    func wallDeadline() async throws {
        let host = RLMGuileRecordingHost(blockingSeconds: 5)
        let session = RLMGuileTestSupport.session(host: host) { configuration in
            configuration.cellTimeLimitSeconds = 30
            configuration.maxCPUSeconds = 30
            configuration.wallDeadlineSeconds = 1
            configuration.terminationGraceSeconds = 0.2
        }
        try await session.start()

        let outcome = await session.evaluate(source: "(corpus-search \"q\" 1)")
        #expect(outcome == .timedOut)
        #expect(await session.isRunning == false)

        let late = await session.evaluate(source: "(+ 1 2)")
        #expect(late == .workerExited(-1))
    }

    @Test("the worker installs the process CPU and address-space limits")
    func processLimitsInstalled() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host) { configuration in
            configuration.maxCPUSeconds = 7
            configuration.maxAddressSpaceBytes = 256 * 1_024 * 1_024
        }
        try await session.start()

        let ready = try #require(await session.ready)
        #expect(ready.cpuLimitSeconds == 7)
        #expect(ready.addressSpaceBytes == 256 * 1_024 * 1_024)

        await session.shutdown()
    }

    @Test("the sandbox allocation limit bounds worker memory")
    func memoryLimit() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host) { configuration in
            configuration.cellAllocationLimitBytes = 1_000_000
            configuration.cellTimeLimitSeconds = 5
            configuration.wallDeadlineSeconds = 10
        }
        try await session.start()

        let outcome = await session.evaluate(source: "(make-list 1000000 1)")
        #expect(outcome == .schemeFailed("resource limit exceeded"))

        await session.shutdown()
    }

    @Test("oversized worker output terminates the worker at the parent limit")
    func outputLimit() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host) { configuration in
            configuration.maxOutputBytes = 4_096
        }
        try await session.start()

        let payload = String(repeating: "a", count: 10_000)
        let outcome = await session.evaluate(source: "(string-append \"\(payload)\" \"\")")
        #expect(outcome == .outputLimitReached)
        #expect(await session.isRunning == false)
    }

    @Test("credentials and unrelated file descriptors are absent from the worker")
    func credentialsAbsent() async throws {
        RLMGuileTestSupport.plantSecret("GNOSTIC_RLM_SECRET", value: "leak")
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let ready = try #require(await session.ready)
        #expect(!ready.environmentKeys.contains("GNOSTIC_RLM_SECRET"))
        #expect(!ready.environmentKeys.contains("HOME"))
        #expect(ready.environmentKeys.allSatisfy { !$0.localizedCaseInsensitiveContains("secret") })
        #if os(Linux)
        #expect(ready.openFileDescriptorCount >= 3)
        #expect(ready.openFileDescriptorCount <= 16)
        #else
        #expect(ready.openFileDescriptorCount == -1 || ready.openFileDescriptorCount >= 3)
        #endif

        let rejected = await session.evaluate(source: "(getenv \"GNOSTIC_RLM_SECRET\")")
        #expect(rejected == .cellRejected("disallowed symbol 'getenv'"))

        await session.shutdown()
    }

    @Test("a three-argument leaf query is rejected before evaluation")
    func threeArgumentLeafQueryIsRejected() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(lm-query \"a\" 'fast 'primary)")
        #expect(outcome == .cellRejected("host call 'lm-query' expects 1...2 arguments, got 3"))
        #expect(await host.recorded().isEmpty)

        await session.shutdown()
    }

    @Test("cancellation fences the in-flight worker result")
    func cancellationFences() async throws {
        let token = RLMCancellationToken()
        let host = RLMGuileRecordingHost(cancellation: token)
        let session = RLMGuileTestSupport.session(host: host, cancellation: token)
        try await session.start()

        let outcome = await session.evaluate(source: "(lm-query \"prompt\")")
        #expect(outcome == .cancelled)
        #expect(token.isCancelled)

        await session.shutdown()
    }

    @Test("a host failure is an ordinary structured failure")
    func hostFailure() async throws {
        let host = RLMGuileRecordingHost(leafFailure: .leafModelFailed("provider down"))
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(lm-query \"prompt\")")
        guard case let .schemeFailed(message) = outcome else {
            Issue.record("expected a structured scheme failure, got \(outcome)")
            return
        }
        #expect(message.contains("host call failed"))

        await session.shutdown()
    }

    @Test("a disallowed definition cannot seed a later cell")
    func disallowedDefinitionDoesNotPersist() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let first = await session.evaluate(source: "(define system 1)")
        #expect(first == .cellRejected("disallowed symbol 'system'"))

        let second = await session.evaluate(source: "(system \"echo hi\")")
        #expect(second == .cellRejected("disallowed symbol 'system'"))

        await session.shutdown()
    }

    @Test("a runtime-malformed finish is a structured failure")
    func runtimeMalformedFinish() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let outcome = await session.evaluate(source: "(define bad (list 1 2)) (finish \"a\" bad)")
        guard case let .schemeFailed(message) = outcome else {
            Issue.record("expected a structured failure, got \(outcome)")
            return
        }
        #expect(message.contains("finish evidence entries must be chunk identifier strings"))

        await session.shutdown()
    }

    @Test("flat lists longer than the depth budget are preserved")
    func longFlatListPreserved() async throws {
        let host = RLMGuileRecordingHost()
        let session = RLMGuileTestSupport.session(host: host)
        try await session.start()

        let count = 100
        let source = "(list " + (0..<count).map(String.init).joined(separator: " ") + ")"
        let outcome = await session.evaluate(source: source)
        #expect(outcome == .value(.list((0..<count).map { .integer($0) })))

        await session.shutdown()
    }

    @Test("an oversized host result is surfaced instead of swallowed")
    func oversizedHostResult() async throws {
        let host = RLMGuileRecordingHost(oversizedChunkBytes: 10_000)
        let session = RLMGuileTestSupport.session(host: host) { configuration in
            configuration.maxOutputBytes = 4_096
            configuration.wallDeadlineSeconds = 10
        }
        try await session.start()

        let outcome = await session.evaluate(source: "(corpus-read \"c-1\")")
        guard case .hostResultRejected = outcome else {
            Issue.record("expected a surfaced host-result rejection, got \(outcome)")
            return
        }
        #expect(await session.isRunning == false)
    }
}

@Suite("RLM Guile worker configuration")
struct RLMGuileWorkerConfigurationTests {
    @Test("a missing executable is reported before spawning")
    func missingExecutable() async {
        let session = RLMGuileWorkerSession(
            configuration: RLMGuileWorkerConfiguration(
                runID: "run",
                workerScriptPath: "/nonexistent/worker.scm",
                executablePath: "/nonexistent/guile"
            ),
            host: RLMGuileRecordingHost()
        )
        await #expect(throws: RLMGuileWorkerError.executableMissing("/nonexistent/guile")) {
            try await session.start()
        }
    }

    @Test("the default environment carries no credentials")
    func scrubbedEnvironment() {
        let environment = RLMGuileWorkerConfiguration.scrubbedEnvironment
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(environment["GUILE_AUTO_COMPILE"] == "0")
        #expect(environment.keys.allSatisfy { !$0.localizedCaseInsensitiveContains("secret") })
        #expect(environment.keys.allSatisfy { !$0.localizedCaseInsensitiveContains("token") })
    }
}
