// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM restricted S-expressions")
struct RLMSExpressionTests {
    @Test("parses atoms, lists, quotes, vectors, and comments")
    func parseBasics() throws {
        let forms = try RLMSExpressionParser.parse(
            """
            ; a comment
            (corpus-search "retirement" 4)
            'fast
            #(1 2 3)
            #t #f -3 2.5
            """
        )
        #expect(forms.count == 7)
        #expect(forms[0] == .list([
            .symbol("corpus-search"), .string("retirement"), .integer(4),
        ]))
        #expect(forms[1] == .list([.symbol("quote"), .symbol("fast")]))
        #expect(forms[2] == .vector([.integer(1), .integer(2), .integer(3)]))
        #expect(forms[3] == .boolean(true))
        #expect(forms[4] == .boolean(false))
        #expect(forms[5] == .integer(-3))
        #expect(forms[6] == .double(2.5))
    }

    @Test("parses string escapes and preserves content")
    func parseStrings() throws {
        let forms = try RLMSExpressionParser.parse("\"line\\nquote\\\"tab\\t\"")
        #expect(forms == [.string("line\nquote\"tab\t")])
    }

    @Test("round-trips through the canonical writer")
    func roundTrip() throws {
        let source = "(finish \"answer\" (\"c-1\" \"c-2\"))"
        let forms = try RLMSExpressionParser.parse(source)
        let rewritten = forms.map(\.written).joined(separator: " ")
        #expect(try RLMSExpressionParser.parse(rewritten) == forms)
    }

    @Test("rejects malformed programs")
    func malformed() {
        #expect(throws: RLMSExpressionParseError.unterminatedString) {
            try RLMSExpressionParser.parse("\"unterminated")
        }
        #expect(throws: RLMSExpressionParseError.unterminatedList) {
            try RLMSExpressionParser.parse("(a b")
        }
        #expect(throws: RLMSExpressionParseError.unexpectedCloseParenthesis(offset: 0)) {
            try RLMSExpressionParser.parse(")")
        }
        #expect(throws: RLMSExpressionParseError.unexpectedToken("#.")) {
            try RLMSExpressionParser.parse("#.(evil)")
        }
    }
}
