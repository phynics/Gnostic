// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import GnosticRLM
import GnosticRLMChibi
import GnosticRLMGuile

@Suite("RLM worker wire parity", .enabled(if: RLMWorkerWireParitySupport.isAvailable), .serialized)
struct RLMWorkerWireParityTests {
    @Test("Guile and Chibi produce the same value frame for one corpus fixture")
    func valueFrameMatches() async throws {
        let source = """
        (let* (
            (hits (corpus-search "wire parity" 1))
            (chunks (corpus-read-many (list "c-1")))
            (numbers (list (/ 1.0 3.0) (expt 2 100) (sqrt -1)))
            (control (string-append "a" "\u{08}" "b")))
          (list hits chunks numbers control
                (list (string->symbol "gnostic-unsupported")
                      (string->symbol "valid-symbol"))))
        """

        let guileHost = RLMGuileClosureHost { operation in
            try RLMWorkerWireParitySupport.observation(for: operation)
        }
        let chibiHost = RLMChibiClosureHost { operation in
            try RLMWorkerWireParitySupport.observation(for: operation)
        }
        let guile = RLMWorkerWireParitySupport.guileSession(host: guileHost)
        let chibi = RLMWorkerWireParitySupport.chibiSession(host: chibiHost)
        try await guile.start()
        try await chibi.start()

        let guileOutcome = await guile.evaluate(source: source)
        let chibiOutcome = await chibi.evaluate(source: source)
        await guile.shutdown()
        await chibi.shutdown()
        guard case let .value(guileValue) = guileOutcome else {
            Issue.record("Guile did not return a value frame: \(guileOutcome)")
            return
        }
        guard case let .value(chibiValue) = chibiOutcome else {
            Issue.record("Chibi did not return a value frame: \(chibiOutcome)")
            return
        }
        if guileValue != chibiValue {
            Issue.record("wire values differ: Guile=\(guileValue?.written ?? "nil") Chibi=\(chibiValue?.written ?? "nil")")
        }
    }

    @Test("both workers sanitize ready-frame environment metadata")
    func readyFrameSanitizesEnvironment() async throws {
        var environment = RLMGuileWorkerConfiguration.scrubbedEnvironment
        environment["A\u{8}B"] = "value"
        environment["C\u{7}D"] = "value"

        let guileHost = RLMGuileClosureHost { operation in
            try RLMWorkerWireParitySupport.observation(for: operation)
        }
        let chibiHost = RLMChibiClosureHost { operation in
            try RLMWorkerWireParitySupport.observation(for: operation)
        }
        let guile = RLMWorkerWireParitySupport.guileSession(host: guileHost, environment: environment)
        let chibi = RLMWorkerWireParitySupport.chibiSession(host: chibiHost, environment: environment)
        try await guile.start()
        try await chibi.start()

        let guileReady = try #require(await guile.ready)
        let chibiReady = try #require(await chibi.ready)
        await guile.shutdown()
        await chibi.shutdown()

        #expect(guileReady.runID == "parity-guile")
        #expect(chibiReady.runID == "parity-chibi")
        #expect(guileReady.environmentKeys.contains("A?B"))
        #expect(chibiReady.environmentKeys.contains("A?B"))
        #expect(guileReady.environmentKeys.contains("C?D"))
        #expect(chibiReady.environmentKeys.contains("C?D"))
        #expect(!guileReady.environmentKeys.contains("A\u{8}B"))
        #expect(!chibiReady.environmentKeys.contains("A\u{8}B"))
    }

    @Test("string-split accepts an ordinary string delimiter and preserves empty fields")
    func stringSplitAcceptsStringDelimiter() async throws {
        let outcomes = try await RLMWorkerWireParitySupport.evaluateBoth(
            "(list (string-split \"a--b--\" \"--\") (string-split \"\" \",\") (string-split \",a,,b,\" \",\"))"
        )
        let expected = RLMSExpression.list([
            .list([.string("a"), .string("b"), .string("")]),
            .list([.string("")]),
            .list([.string(""), .string("a"), .string(""), .string("b"), .string("")]),
        ])
        #expect(outcomes.guile == .value(expected))
        #expect(outcomes.chibi == .value(expected))
    }

    @Test("sort preserves equal-key order")
    func sortIsStableForEqualKeys() async throws {
        let outcomes = try await RLMWorkerWireParitySupport.evaluateBoth(
            """
            (sort '((1 "a") (1 "b") (0 "z") (1 "c") (1 "d"))
                  (lambda (left right) (< (car left) (car right))))
            """
        )
        let expected = RLMSExpression.list([
            .list([.integer(0), .string("z")]),
            .list([.integer(1), .string("a")]),
            .list([.integer(1), .string("b")]),
            .list([.integer(1), .string("c")]),
            .list([.integer(1), .string("d")]),
        ])
        #expect(outcomes.guile == .value(expected))
        #expect(outcomes.chibi == .value(expected))
    }

    @Test("sort accepts vectors and preserves the input sequence type")
    func sortAcceptsVectors() async throws {
        let outcomes = try await RLMWorkerWireParitySupport.evaluateBoth(
            "(list (vector? (sort (vector 3 1 2) <)) (vector->list (sort (vector 3 1 2) <)))"
        )
        let expected = RLMSExpression.list([
            .boolean(true),
            .list([.integer(1), .integer(2), .integer(3)]),
        ])
        #expect(outcomes.guile == .value(expected))
        #expect(outcomes.chibi == .value(expected))
    }

    @Test("loop and deep-recursion stress cells fail without losing either worker")
    func containmentStressRecoversBothWorkers() async throws {
        let fixtures = [
            (name: "loop", source: "(define (spin n) (spin n)) (spin 0)"),
            (
                name: "deep recursion",
                source: "(define (deep n) (if (= n 0) 0 (+ 1 (deep (- n 1))))) (deep 1000000)"
            ),
        ]
        for fixture in fixtures {
            _ = try RLMSchemeProfile.validate(fixture.source)
        }

        let (guile, chibi) = RLMWorkerWireParitySupport.containmentSessions()
        try await guile.start()
        do {
            try await chibi.start()
        } catch {
            await guile.shutdown()
            throw error
        }

        for fixture in fixtures {
            let guileOutcome = await guile.evaluate(source: fixture.source)
            let chibiOutcome = await chibi.evaluate(source: fixture.source)
            #expect(Self.isRepairableSchemeFailure(guileOutcome), "Guile \(fixture.name) result: \(guileOutcome)")
            #expect(Self.isRepairableSchemeFailure(chibiOutcome), "Chibi \(fixture.name) result: \(chibiOutcome)")
            #expect(await guile.isRunning, "Guile worker exited after \(fixture.name)")
            #expect(await chibi.isRunning, "Chibi worker exited after \(fixture.name)")

            #expect(await guile.evaluate(source: "(+ 1 2)") == .value(.integer(3)))
            #expect(await chibi.evaluate(source: "(+ 1 2)") == .value(.integer(3)))
        }

        await guile.shutdown()
        await chibi.shutdown()
    }

    @Test("every profile pure operation is usable and has worker parity")
    func pureOperationCorpusMatches() async throws {
        #expect(Set(Self.pureOperationSources.keys) == RLMSchemeProfile.pureOperations)
        for source in Self.pureOperationSources.values {
            _ = try RLMSchemeProfile.validate(source)
        }

        let (guile, chibi) = RLMWorkerWireParitySupport.sessions()
        try await guile.start()
        do {
            try await chibi.start()
        } catch {
            await guile.shutdown()
            throw error
        }

        for operation in RLMSchemeProfile.pureOperations.sorted() {
            let source = try #require(Self.pureOperationSources[operation])
            let guileOutcome = await guile.evaluate(source: source)
            let chibiOutcome = await chibi.evaluate(source: source)
            #expect(Self.isValue(guileOutcome), "Guile could not use profile operation `\(operation)`: \(guileOutcome)")
            #expect(Self.isValue(chibiOutcome), "Chibi could not use profile operation `\(operation)`: \(chibiOutcome)")
            #expect(guileOutcome == chibiOutcome, "`\(operation)` differs: Guile=\(guileOutcome), Chibi=\(chibiOutcome)")
        }

        let emptyAndNumericEdges = """
        (list (string-split "" ",")
              (string-split ",a,,b," ",")
              (sort '() <)
              (map (lambda (value) (+ value 1)) '())
              (modulo -8 3)
              (quotient -8 3))
        """
        let guileEdges = await guile.evaluate(source: emptyAndNumericEdges)
        let chibiEdges = await chibi.evaluate(source: emptyAndNumericEdges)
        let expectedEdges = RLMSExpression.list([
            .list([.string("")]),
            .list([.string(""), .string("a"), .string(""), .string("b"), .string("")]),
            .list([]),
            .list([]),
            .integer(1),
            .integer(-2),
        ])
        #expect(guileEdges == .value(expectedEdges), "Guile empty/numeric edges differ: \(guileEdges)")
        #expect(chibiEdges == .value(expectedEdges), "Chibi empty/numeric edges differ: \(chibiEdges)")

        let guileUTF8 = await guile.evaluate(source: "(string-length \"café\")")
        let chibiUTF8 = await chibi.evaluate(source: "(string-length \"café\")")
        #expect(guileUTF8 == .value(.integer(4)))
        #expect(chibiUTF8 == .value(.integer(5)))

        await guile.shutdown()
        await chibi.shutdown()
    }

    private static func isValue(_ outcome: RLMWorkerEvaluationOutcome) -> Bool {
        if case .value = outcome { return true }
        return false
    }

    private static func isRepairableSchemeFailure(_ outcome: RLMWorkerEvaluationOutcome) -> Bool {
        guard case let .schemeFailed(message) = outcome else { return false }
        return RLMWorkerFailureClassifier.classify(message).isRecoverableCellFailure
    }

    private static let pureOperationSources: [String: String] = [
        "+": "(+ 1 2 3)",
        "-": "(- 9 4 2)",
        "*": "(* 2 3 4)",
        "/": "(/ 8 2)",
        "quotient": "(quotient -8 3)",
        "remainder": "(remainder -8 3)",
        "modulo": "(modulo -8 3)",
        "abs": "(abs -8)",
        "min": "(min 3 -2 9)",
        "max": "(max 3 -2 9)",
        "expt": "(expt 2 10)",
        "sqrt": "(sqrt 9)",
        "gcd": "(gcd 12 18 30)",
        "lcm": "(lcm 3 4 5)",
        "floor": "(floor -1.2)",
        "ceiling": "(ceiling -1.2)",
        "round": "(round 1.6)",
        "truncate": "(truncate -1.8)",
        "=": "(= 3 3.0)",
        "<": "(< -1 0)",
        ">": "(> 2 1)",
        "<=": "(<= 2 2)",
        ">=": "(>= 2 2)",
        "zero?": "(zero? 0)",
        "positive?": "(positive? 2)",
        "negative?": "(negative? -2)",
        "odd?": "(odd? 3)",
        "even?": "(even? 4)",
        "number?": "(number? 3)",
        "integer?": "(integer? 3)",
        "exact?": "(exact? 3)",
        "inexact?": "(inexact? 3.5)",
        "not": "(not #f)",
        "eq?": "(eq? 'same 'same)",
        "eqv?": "(eqv? 3 3)",
        "equal?": "(equal? '(a b) '(a b))",
        "string?": "(string? \"text\")",
        "string-append": "(string-append \"gn\" \"ostic\")",
        "string-length": "(string-length \"gnostic\")",
        "string-ref": "(eqv? (string-ref \"abc\" 1) (string-ref \"abc\" 1))",
        "substring": "(substring \"gnostic\" 0 4)",
        "string=?": "(string=? \"same\" \"same\")",
        "string<?": "(string<? \"a\" \"b\")",
        "string>?": "(string>? \"b\" \"a\")",
        "string<=?": "(string<=? \"a\" \"a\")",
        "string>=?": "(string>=? \"b\" \"b\")",
        "string-contains": "(string-contains \"abcdef\" \"cd\")",
        "string-split": "(string-split \"a--b--\" \"--\")",
        "string-join": "(string-join '(\"a\" \"b\" \"c\") \"-\")",
        "string-upcase": "(string-upcase \"Abc\")",
        "string-downcase": "(string-downcase \"AbC\")",
        "string->list": "(length (string->list \"abc\"))",
        "list->string": "(list->string (string->list \"abc\"))",
        "make-string": "(make-string 3 (string-ref \"x\" 0))",
        "number->string": "(number->string 42)",
        "string->number": "(string->number \"42\")",
        "symbol?": "(symbol? 'symbol)",
        "symbol->string": "(symbol->string 'symbol)",
        "string->symbol": "(string->symbol \"symbol\")",
        "list": "(list 1 2 3)",
        "list?": "(list? '(1 2))",
        "pair?": "(pair? '(1))",
        "null?": "(null? '())",
        "cons": "(cons 1 '(2 3))",
        "car": "(car '(1 2))",
        "cdr": "(cdr '(1 2))",
        "caar": "(caar '((1 2) (3 4)))",
        "cadr": "(cadr '(1 2 3))",
        "cdar": "(cdar '((1 2) (3 4)))",
        "cddr": "(cddr '(1 2 3 4))",
        "caddr": "(caddr '(1 2 3 4))",
        "cadddr": "(cadddr '(1 2 3 4))",
        "length": "(length '(1 2 3))",
        "append": "(append '(1 2) '(3 4))",
        "reverse": "(reverse '(1 2 3))",
        "list-ref": "(list-ref '(a b c) 1)",
        "list-tail": "(list-tail '(a b c) 1)",
        "make-list": "(make-list 3 'x)",
        "member": "(member 'b '(a b c))",
        "memq": "(memq 'b '(a b c))",
        "memv": "(memv 2 '(1 2 3))",
        "assoc": "(assoc 'b '((a 1) (b 2)))",
        "assq": "(assq 'b '((a 1) (b 2)))",
        "assv": "(assv 2 '((1 a) (2 b)))",
        "map": "(map (lambda (value) (+ value 1)) '(1 2 3))",
        "for-each": "(for-each (lambda (value) (+ value 1)) '(1 2 3))",
        "filter": "(filter (lambda (value) (positive? value)) '(-1 0 1 2))",
        "sort": "(sort '(3 1 2) <)",
        "apply": "(apply + '(1 2 3))",
        "vector?": "(vector? (vector 1))",
        "vector": "(vector 1 2 3)",
        "vector-length": "(vector-length (vector 1 2 3))",
        "vector-ref": "(vector-ref (vector 1 2 3) 1)",
        "vector->list": "(vector->list (vector 1 2 3))",
        "list->vector": "(list->vector '(1 2 3))",
        "make-vector": "(vector->list (make-vector 3 7))",
    ]
}

private enum RLMWorkerWireParitySupport {
    static var guilePath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["GNOSTIC_GUILE"],
            "/usr/bin/guile",
            "/opt/homebrew/bin/guile",
            "/usr/local/bin/guile",
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static var chibiPath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["GNOSTIC_CHIBI"],
            "/opt/homebrew/bin/chibi-scheme",
            "/usr/bin/chibi-scheme",
            "/usr/local/bin/chibi-scheme",
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static var guileScriptPath: String {
        RLMGuileWorkerConfiguration.defaultWorkerScriptPath ?? ""
    }

    static var chibiScriptPath: String {
        RLMChibiWorkerConfiguration.defaultWorkerScriptPath ?? ""
    }

    static var isAvailable: Bool {
        guilePath != nil
            && chibiPath != nil
            && FileManager.default.fileExists(atPath: guileScriptPath)
            && FileManager.default.fileExists(atPath: chibiScriptPath)
    }

    static func guileSession(
        host: any RLMGuileHost,
        runID: String = "parity-guile",
        environment: [String: String] = RLMGuileWorkerConfiguration.scrubbedEnvironment
    ) -> RLMGuileWorkerSession {
        RLMGuileWorkerSession(
            configuration: RLMGuileWorkerConfiguration(
                runID: runID,
                workerScriptPath: guileScriptPath,
                executablePath: guilePath ?? "/usr/bin/guile",
                environment: environment
            ),
            host: host
        )
    }

    static func chibiSession(
        host: any RLMChibiHost,
        runID: String = "parity-chibi",
        environment: [String: String] = RLMChibiWorkerConfiguration.scrubbedEnvironment
    ) -> RLMChibiWorkerSession {
        RLMChibiWorkerSession(
            configuration: RLMChibiWorkerConfiguration(
                runID: runID,
                workerScriptPath: chibiScriptPath,
                executablePath: chibiPath ?? RLMChibiWorkerConfiguration.defaultExecutablePath,
                environment: environment
            ),
            host: host
        )
    }

    static func evaluateBoth(
        _ source: String
    ) async throws -> (guile: RLMWorkerEvaluationOutcome, chibi: RLMWorkerEvaluationOutcome) {
        let (guile, chibi) = sessions()
        try await guile.start()
        do {
            try await chibi.start()
        } catch {
            await guile.shutdown()
            throw error
        }
        let guileOutcome = await guile.evaluate(source: source)
        let chibiOutcome = await chibi.evaluate(source: source)
        await guile.shutdown()
        await chibi.shutdown()
        return (guileOutcome, chibiOutcome)
    }

    static func sessions() -> (guile: RLMGuileWorkerSession, chibi: RLMChibiWorkerSession) {
        let guileHost = RLMGuileClosureHost { operation in
            try observation(for: operation)
        }
        let chibiHost = RLMChibiClosureHost { operation in
            try observation(for: operation)
        }
        return (guileSession(host: guileHost), chibiSession(host: chibiHost))
    }

    static func containmentSessions() -> (guile: RLMGuileWorkerSession, chibi: RLMChibiWorkerSession) {
        let guileHost = RLMGuileClosureHost { operation in
            try observation(for: operation)
        }
        let chibiHost = RLMChibiClosureHost { operation in
            try observation(for: operation)
        }
        let guileConfiguration = RLMGuileWorkerConfiguration(
            runID: "stress-guile",
            workerScriptPath: guileScriptPath,
            executablePath: guilePath ?? RLMGuileWorkerConfiguration.defaultExecutablePath,
            cellTimeLimitSeconds: 0.25,
            cellAllocationLimitBytes: 1_024 * 1_024,
            wallDeadlineSeconds: 5
        )
        let chibiConfiguration = RLMChibiWorkerConfiguration(
            runID: "stress-chibi",
            workerScriptPath: chibiScriptPath,
            executablePath: chibiPath ?? RLMChibiWorkerConfiguration.defaultExecutablePath,
            maxHeapBytes: 32 * 1_024 * 1_024,
            cellTimeLimitSeconds: 0.25,
            cellAllocationLimitBytes: 1_024 * 1_024,
            wallDeadlineSeconds: 5
        )
        return (
            RLMGuileWorkerSession(configuration: guileConfiguration, host: guileHost),
            RLMChibiWorkerSession(configuration: chibiConfiguration, host: chibiHost)
        )
    }

    static func observation(for operation: RLMHostOperation) throws -> RLMHostObservation {
        switch operation {
        case let .corpusSearch(query, limit):
            return .corpusSearch(
                hits: [
                    RLMSearchHit(
                        chunkID: "c-1",
                        path: "Sources/Parity.swift",
                        startLine: 4,
                        endLine: 8,
                        preview: "\(query) \(limit)",
                        score: 1
                    ),
                ],
                bytesRead: 18
            )
        case let .corpusRead(chunkIDs):
            return .corpusRead(
                chunks: chunkIDs.map { identifier in
                    RLMCorpusChunk(
                        id: identifier,
                        path: "Sources/Parity.swift",
                        startLine: 4,
                        endLine: 8,
                        content: "same corpus \(identifier)",
                        byteCount: 18,
                        digest: "parity-digest"
                    )
                },
                bytesRead: chunkIDs.count * 18
            )
        case let .leafQuery(prompts, _):
            return .leaf(responses: prompts.map { "response:\($0)" }, estimatedTokens: prompts.count)
        case .progress:
            return .progress
        case .finish:
            throw RLMFailure.evaluatorFailed("finish must not be serviced as a host operation")
        }
    }
}
