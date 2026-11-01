// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

import GnosticCore

@Suite("RFC 8785 canonical JSON")
struct CanonicalJSONTests {
    private func canonical(_ json: String) throws -> String {
        let value = try JSONDecoder().decode(GnosticJSONValue.self, from: Data(json.utf8))
        return try CanonicalJSON.string(value)
    }

    /// RFC 8785 section 3.2.2: the worked example, covering number and string
    /// serialization and literal members.
    @Test("matches the RFC 8785 section 3.2.2 example")
    func sectionThreeTwoTwoExample() throws {
        let input = #"""
        {
          "numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
          "string": "\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/",
          "literals": [null, true, false]
        }
        """#
        let expected = #"{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}"#
        #expect(try canonical(input) == expected)
    }

    /// RFC 8785 section 3.2.3: members sort by UTF-16 code units. U+1F600 is
    /// the surrogate pair D83D DE00, which sorts before U+FB33.
    @Test("sorts members by UTF-16 code units, as RFC 8785 section 3.2.3 requires")
    func sectionThreeTwoThreeSorting() throws {
        let input = #"""
        {
          "\u20ac": "Euro Sign",
          "\r": "Carriage Return",
          "\ufb33": "Hebrew Letter Dalet With Dagesh",
          "1": "One",
          "\ud83d\ude00": "Emoji: Grinning Face",
          "\u0080": "Control",
          "\u00f6": "Latin Small Letter O With Diaeresis"
        }
        """#
        let value = try JSONDecoder().decode(GnosticJSONValue.self, from: Data(input.utf8))
        let output = try CanonicalJSON.string(value)
        let names = try #require(
            (try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        )
        #expect(names.count == 7)
        // The keys appear in the output in this order.
        let order = ["\r", "1", "\u{80}", "\u{f6}", "\u{20ac}", "\u{1F600}", "\u{fb33}"]
        var cursor = output.startIndex
        for name in order {
            let needle = try CanonicalJSON.string(.string(name)) + ":"
            let range = try #require(output.range(of: needle, range: cursor..<output.endIndex))
            cursor = range.upperBound
        }
    }

    @Test("escapes exactly the characters RFC 8785 section 3.2.2.2 lists")
    func stringEscaping() throws {
        let value = GnosticJSONValue.string("\u{8}\t\n\u{c}\r\"\\\u{0}\u{1f}/\u{7f}\u{2028}é😀")
        #expect(try CanonicalJSON.string(value) == "\"\\b\\t\\n\\f\\r\\\"\\\\\\u0000\\u001f/\u{7f}\u{2028}é😀\"")
    }

    /// RFC 8785 appendix B: IEEE 754 bit patterns and their ES6 text.
    @Test(
        "formats numbers as RFC 8785 appendix B requires",
        arguments: [
            (UInt64(0x0000_0000_0000_0000), "0"),
            (0x8000_0000_0000_0000, "0"),
            (0x0000_0000_0000_0001, "5e-324"),
            (0x8000_0000_0000_0001, "-5e-324"),
            (0x7fef_ffff_ffff_ffff, "1.7976931348623157e+308"),
            (0xffef_ffff_ffff_ffff, "-1.7976931348623157e+308"),
            (0x4340_0000_0000_0000, "9007199254740992"),
            (0xc340_0000_0000_0000, "-9007199254740992"),
            (0x4430_0000_0000_0000, "295147905179352830000"),
            (0x44b5_2d02_c7e1_4af5, "9.999999999999997e+22"),
            (0x44b5_2d02_c7e1_4af6, "1e+23"),
            (0x44b5_2d02_c7e1_4af7, "1.0000000000000001e+23"),
            (0x444b_1ae4_d6e2_ef4e, "999999999999999700000"),
            (0x444b_1ae4_d6e2_ef4f, "999999999999999900000"),
            (0x444b_1ae4_d6e2_ef50, "1e+21"),
            (0x3eb0_c6f7_a0b5_ed8c, "9.999999999999997e-7"),
            (0x3eb0_c6f7_a0b5_ed8d, "0.000001"),
            (0x41b3_de43_5555_5553, "333333333.3333332"),
            (0x41b3_de43_5555_5554, "333333333.33333325"),
            (0x41b3_de43_5555_5555, "333333333.3333333"),
            (0x41b3_de43_5555_5556, "333333333.3333334"),
            (0x41b3_de43_5555_5557, "333333333.33333343"),
            (0xbecb_f647_612f_3696, "-0.0000033333333333333333"),
            (0x4314_3ff3_c1cb_0959, "1424953923781206.2"),
        ]
    )
    func appendixBNumbers(bits: UInt64, expected: String) throws {
        #expect(try CanonicalJSON.number(Double(bitPattern: bits)) == expected)
    }

    @Test("rejects NaN and infinities, which RFC 8785 cannot represent")
    func nonFiniteNumbers() {
        #expect(throws: CanonicalJSON.Error.nonFiniteNumber) { try CanonicalJSON.string(.number(.nan)) }
        #expect(throws: CanonicalJSON.Error.nonFiniteNumber) { try CanonicalJSON.string(.number(.infinity)) }
    }

    @Test("an integer beyond 2^53 takes the double's ES6 form")
    func largeIntegers() throws {
        #expect(try CanonicalJSON.string(.integer(9_007_199_254_740_992)) == "9007199254740992")
        #expect(try CanonicalJSON.string(.integer(Int64.max)) == "9223372036854776000")
        #expect(try CanonicalJSON.string(.unsignedInteger(UInt64.max)) == "18446744073709552000")
    }

    @Test("the Turn admission digest covers the prompt content and the ACP version tag")
    func digestCoversPromptAndVersionTag() throws {
        let a = try TurnAdmissionDigest.hex(
            prompt: [.text(ACPTextContent(text: "hello"))], acpVersionTag: ACPv2Protocol.versionTag
        )
        let b = try TurnAdmissionDigest.hex(
            prompt: [.text(ACPTextContent(text: "hello"))], acpVersionTag: ACPv2Protocol.versionTag
        )
        let otherTag = try TurnAdmissionDigest.hex(
            prompt: [.text(ACPTextContent(text: "hello"))], acpVersionTag: "other"
        )
        let otherText = try TurnAdmissionDigest.hex(
            prompt: [.text(ACPTextContent(text: "hellp"))], acpVersionTag: ACPv2Protocol.versionTag
        )
        #expect(a == b)
        #expect(a != otherTag)
        #expect(a != otherText)
        #expect(a.count == 64)
        #expect(a == SHA256.hexDigest(
            #"{"acpVersionTag":"\#(ACPv2Protocol.versionTag)","prompt":[{"text":"hello","type":"text"}]}"#
        ))
    }
}
