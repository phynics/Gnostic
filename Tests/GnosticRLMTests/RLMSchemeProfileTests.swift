// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM Scheme 0 profile")
struct RLMSchemeProfileTests {
    private let epicExample = """
    (let* (
        (hits (corpus-search "backend retirement lease generation stale completion" 24))
        (chunk-ids (map (lambda (hit) (cdr (assq 'chunk-id hit))) hits))
        (documents (corpus-read-many chunk-ids))
        (prompts (map (lambda (document) (string-append "Extract the mechanism: " document)) documents))
        (findings (lm-query-batched prompts 'fast))
        (synthesis (lm-query (string-append "Synthesize: " (string-join findings "\\n\\n")) 'primary)))
      (finish synthesis chunk-ids))
    """

    @Test("accepts the profile fixture and records feature usage")
    func acceptsFixture() throws {
        let validation = try RLMSchemeProfile.validate(epicExample)
        #expect(validation.profile == "gnostic-rlm-scheme-0")
        #expect(validation.hostCallCount == 5)
        #expect(validation.usage.hostCalls == [
            "corpus-search", "corpus-read-many", "lm-query-batched", "lm-query", "finish",
        ])
        #expect(validation.usage.specialForms == ["let*", "lambda", "quote"])
        #expect(validation.usage.pureOperations.contains("map"))
        #expect(validation.usage.pureOperations.contains("assq"))
        #expect(validation.usage.pureOperations.contains("string-join"))
        #expect(validation.usage.userDefinitions.isEmpty)
        #expect(validation.usage.maxDepth > 1)
    }

    @Test("records user definitions for later cells")
    func recordsDefinitions() throws {
        let usage = try RLMSchemeProfile.analyze("(define findings (list 1 2 3))")
        #expect(usage.userDefinitions == ["findings"])
        #expect(usage.specialForms == ["define"])
    }

    @Test("rejects disallowed syntax and facilities")
    func rejectsMaliciousCorpus() {
        let corpus: [(String, RLMSchemeValidationError)] = [
            ("(set! x 1)", .disallowedSymbol("set!")),
            ("(define-syntax foo (syntax-rules () ((_) 1)))", .disallowedSymbol("define-syntax")),
            ("(let-syntax ((m (syntax-rules () ((_) 1)))) (m))", .disallowedSymbol("let-syntax")),
            ("(letrec-syntax ((m (syntax-rules () ((_) 1)))) (m))", .disallowedSymbol("letrec-syntax")),
            ("(eval '(+ 1 2))", .disallowedSymbol("eval")),
            ("(load \"x.scm\")", .disallowedSymbol("load")),
            ("(include \"x.scm\")", .disallowedSymbol("include")),
            ("(import (ice-9 sandbox))", .disallowedSymbol("import")),
            ("(use-modules (ice-9 popen))", .disallowedSymbol("use-modules")),
            ("(dynamic-wind (lambda () 1) (lambda () 2) (lambda () 3))", .disallowedSymbol("dynamic-wind")),
            ("(call/cc (lambda (k) (k 1)))", .disallowedSymbol("call/cc")),
            ("(open-input-file \"/etc/passwd\")", .disallowedSymbol("open-input-file")),
            ("(delete-file \"x\")", .disallowedSymbol("delete-file")),
            ("(system \"sh\")", .disallowedSymbol("system")),
            ("(getenv \"HOME\")", .disallowedSymbol("getenv")),
            ("(open-pipe \"ls\" \"r\")", .disallowedSymbol("open-pipe")),
            ("(dynamic-link \"libc\")", .disallowedSymbol("dynamic-link")),
            ("(random 10)", .disallowedSymbol("random")),
            ("(get-internal-real-time)", .disallowedSymbol("get-internal-real-time")),
            ("(string-match \"a\" \"abc\")", .disallowedSymbol("string-match")),
            ("(make-thread (lambda () 1))", .disallowedSymbol("make-thread")),
            ("(display \"x\")", .disallowedSymbol("display")),
            ("#\\a", .unsupportedValue("character literals are not in the profile")),
        ]
        for (source, expected) in corpus {
            #expect(throws: expected) {
                try RLMSchemeProfile.validate(source)
            }
        }
    }

    @Test("rejects reserved redefinition, arity, ordering, and finish placement")
    func rejectsStructuralViolations() {
        #expect(throws: RLMSchemeValidationError.reservedRedefinition("finish")) {
            try RLMSchemeProfile.validate("(define finish 1)")
        }
        #expect(throws: RLMSchemeValidationError.invalidArity(symbol: "corpus-search", expected: "2...2", actual: 1)) {
            try RLMSchemeProfile.validate("(corpus-search \"q\")")
        }
        #expect(throws: RLMSchemeValidationError.invalidArity(symbol: "lm-query", expected: "1...2", actual: 0)) {
            try RLMSchemeProfile.validate("(lm-query)")
        }
        #expect(throws: RLMSchemeValidationError.invalidArity(symbol: "finish", expected: "2...2", actual: 1)) {
            try RLMSchemeProfile.validate("(finish \"a\")")
        }
        #expect(throws: RLMSchemeValidationError.unorderedHostCalls) {
            try RLMSchemeProfile.validate("(string-append (corpus-read \"a\") (corpus-read \"b\"))")
        }
        #expect(throws: RLMSchemeValidationError.unorderedHostCalls) {
            try RLMSchemeProfile.validate("(let ((a (corpus-read \"a\")) (b (corpus-read \"b\"))) a)")
        }
        #expect(throws: RLMSchemeValidationError.invalidFinishPlacement) {
            try RLMSchemeProfile.validate("(begin (finish \"a\" (list)) (progress \"late\"))")
        }
        #expect(throws: RLMSchemeValidationError.invalidFinishPlacement) {
            try RLMSchemeProfile.validate("(if (finish \"a\" (list)) 1 2)")
        }
    }

    @Test("allows ordered effects through let* and begin")
    func allowsOrderedEffects() throws {
        let validation = try RLMSchemeProfile.validate(
            "(let* ((hits (corpus-search \"q\" 4)) (chunks (corpus-read-many (list \"c-1\")))) (progress \"ok\") (finish \"a\" (list \"c-1\")))"
        )
        #expect(validation.hostCallCount == 4)
    }

    @Test("rejects programs over structural limits")
    func rejectsOversized() {
        let deep = String(repeating: "(+ 1 ", count: 80) + "1" + String(repeating: ")", count: 80)
        #expect(throws: RLMSchemeValidationError.excessiveDepth(limit: 64)) {
            try RLMSchemeProfile.validate(deep)
        }
        #expect(throws: RLMSchemeValidationError.excessiveProgramSize(limit: 16)) {
            try RLMSchemeProfile.validate("(+ 1 2 3 4 5 6 7 8 9 10)", limits: RLMSchemeProfile.Limits(
                maxSourceBytes: 16, maxDepth: 64, maxNodes: 8_192, maxForms: 512,
                maxLiteralCollectionElements: 2_048, maxIntegerMagnitude: 1_000_000_000_000,
                maxStringLength: 16 * 1_024
            ))
        }
        #expect(throws: RLMSchemeValidationError.unsupportedValue("integer literal out of range")) {
            try RLMSchemeProfile.validate("1000000000001")
        }
        #expect(throws: RLMSchemeValidationError.excessiveLiteral(limit: 4)) {
            try RLMSchemeProfile.validate("'(1 2 3 4 5)", limits: RLMSchemeProfile.Limits(
                maxSourceBytes: 32 * 1_024, maxDepth: 64, maxNodes: 8_192, maxForms: 512,
                maxLiteralCollectionElements: 4, maxIntegerMagnitude: 1_000_000_000_000,
                maxStringLength: 16 * 1_024
            ))
        }
    }

    @Test("rejects disallowed symbols in definition, parameter, and binding positions")
    func rejectsDisallowedBindings() {
        let cases: [(String, RLMSchemeValidationError)] = [
            ("(define system 1) (system \"echo hi\")", .disallowedSymbol("system")),
            ("(define eval 1) (eval '(+ 1 2))", .disallowedSymbol("eval")),
            ("(define (system x) x)", .disallowedSymbol("system")),
            ("(lambda (system) (system \"x\"))", .disallowedSymbol("system")),
            ("(let ((system 1)) (system \"x\"))", .disallowedSymbol("system")),
            ("(let* ((system 1)) (system \"x\"))", .disallowedSymbol("system")),
            ("(letrec ((system 1)) system)", .disallowedSymbol("system")),
        ]
        for (source, expected) in cases {
            #expect(throws: expected) {
                try RLMSchemeProfile.validate(source)
            }
        }
    }

    @Test("rejects malformed finish arguments before evaluation")
    func rejectsMalformedFinish() {
        #expect(throws: RLMSchemeValidationError.invalidFinishArgument("finish answer must evaluate to a string")) {
            try RLMSchemeProfile.validate("(finish 42 (list \"c\"))")
        }
        #expect(throws: RLMSchemeValidationError.invalidFinishArgument("finish evidence entries must be chunk identifier strings")) {
            try RLMSchemeProfile.validate("(finish \"a\" (list 1 2))")
        }
        #expect(throws: RLMSchemeValidationError.invalidFinishArgument("finish evidence must evaluate to a list of chunk identifiers")) {
            try RLMSchemeProfile.validate("(finish \"a\" \"b\")")
        }
    }

    @Test("accepts well-formed finish arguments")
    func acceptsWellFormedFinish() throws {
        _ = try RLMSchemeProfile.validate("(finish \"answer\" (list \"c-1\"))")
        _ = try RLMSchemeProfile.validate("(finish \"answer\" '(\"c-1\" \"c-2\"))")
        _ = try RLMSchemeProfile.validate("(define synthesis \"a\") (define chunk-ids (list \"c-1\")) (finish synthesis chunk-ids)")
    }

    @Test("accepts a cond => clause")
    func acceptsCondArrow() throws {
        let validation = try RLMSchemeProfile.validate(
            "(define x 1) (cond ((= x 1) => (lambda (v) v)) (else 0))"
        )
        #expect(validation.usage.specialForms.contains("cond"))
        #expect(throws: RLMSchemeValidationError.disallowedSymbol("=>")) {
            try RLMSchemeProfile.validate("(=> 1 2)")
        }
    }

    @Test("rejects non-finite literals in quoted data")
    func rejectsNonFiniteQuoted() {
        #expect(throws: RLMSchemeValidationError.unsupportedValue("non-finite number")) {
            try RLMSchemeProfile.validate("'1e999")
        }
    }

    @Test("rejects malformed and empty cells")
    func rejectsMalformed() {
        #expect(throws: RLMSchemeValidationError.malformedProgram("unterminated string literal")) {
            try RLMSchemeProfile.validate("\"oops")
        }
        #expect(throws: RLMSchemeValidationError.malformedProgram("empty cell")) {
            try RLMSchemeProfile.validate("   ; nothing")
        }
    }
}
