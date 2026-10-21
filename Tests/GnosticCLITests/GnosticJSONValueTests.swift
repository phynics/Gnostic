// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import Testing

@Suite("Gnostic JSON value")
struct GnosticJSONValueTests {
    @Test("Codable round-trip preserves JSON scalar and collection cases")
    func codableRoundTrip() throws {
        let value: GnosticJSONValue = .dictionary([
            "string": .string("hello"),
            "signed": .integer(-12),
            "unsigned": .unsignedInteger(UInt64.max),
            "number": .number(1.25),
            "boolean": .boolean(true),
            "array": .array([.null, .string("nested")]),
        ])

        let decoded = try JSONDecoder().decode(GnosticJSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test("decoding rejects a value that is not JSON")
    func decodingRejectsNonJSON() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GnosticJSONValue.self, from: Data("not json".utf8))
        }
    }

    @Test("decoding keeps signed and unsigned integers distinct")
    func decodingKeepsIntegerWidths() throws {
        let signed = try JSONDecoder().decode(GnosticJSONValue.self, from: Data("-12".utf8))
        #expect(signed == .integer(-12))
        let unsigned = try JSONDecoder().decode(GnosticJSONValue.self, from: Data("18446744073709551615".utf8))
        #expect(unsigned == .unsignedInteger(UInt64.max))
    }
}
