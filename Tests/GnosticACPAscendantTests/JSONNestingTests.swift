// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPAscendant
import Testing

@Suite("JSON nesting scan")
struct JSONNestingTests {
    private func deepest(_ text: String, stoppingAbove limit: Int = .max) -> Int {
        JSONNesting.deepest(in: Array(text.utf8), stoppingAbove: limit)
    }

    @Test("it counts the deepest run of open arrays and objects")
    func countsDepth() {
        #expect(deepest("") == 0)
        #expect(deepest("7") == 0)
        #expect(deepest("{}") == 1)
        #expect(deepest(#"{"a":[1,{"b":[]}],"c":{}}"#) == 4)
        #expect(deepest("[[[]]] [[]]") == 3)
        #expect(deepest(String(repeating: "[", count: 507) + String(repeating: "]", count: 507)) == 507)
    }

    @Test("brackets inside strings do not count")
    func ignoresBracketsInStrings() {
        #expect(deepest(#"{"a":"[[[[{{{{"}"#) == 1)
        #expect(deepest(#"["]]]]","}{"]"#) == 1)
        #expect(deepest(#""[[[[""#) == 0)
    }

    @Test("an escaped quote does not end a string, and an escaped backslash does not escape the quote after it")
    func handlesEscapes() {
        // The string is `x\"[[[` and continues past the escaped quote.
        #expect(deepest(#"{"a":"x\"[[["}"#) == 1)
        // The string is `x\` and ends at the quote that follows the escaped backslash, so the brackets count.
        #expect(deepest(#"{"a":"x\\","b":[[[1]]]}"#) == 4)
        // An escape of a quote at the end of a string keeps the string open to the real closing quote.
        #expect(deepest(#"["a\\\"[[",[]]"#) == 2)
    }

    @Test("non-ASCII text and an unmatched closing bracket do not disturb the count")
    func toleratesOtherBytes() {
        #expect(deepest("{\"a\":\"\u{65E5}\u{1F600}[\",\"b\":[]}") == 2)
        #expect(deepest("]]]}}[[") == 2)
        #expect(deepest("\u{FEFF}[[1]]") == 2)
    }

    @Test("the scan stops above the limit and reports the depth it reached")
    func stopsAboveTheLimit() {
        let text = String(repeating: "[", count: 100_000)
        #expect(deepest(text, stoppingAbove: 128) == 129)
        #expect(deepest(text, stoppingAbove: 128) > JSONNesting.maximumDecodedDepth)
        #expect(!JSONNesting.exceedsMaximumDecodedDepth(Array(String(repeating: "[", count: 128).utf8)))
        #expect(JSONNesting.exceedsMaximumDecodedDepth(Array(String(repeating: "[", count: 129).utf8)))
    }
}
