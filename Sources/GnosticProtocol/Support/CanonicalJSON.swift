// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The JSON Canonicalization Scheme of RFC 8785.
///
/// Gnostic digests a Turn's prompt content with this form (ADR 0021 Turn
/// semantics), so two requests for the same prompt agree on the digest
/// whatever key order or number spelling their encoders chose.
///
/// The scheme has three parts. Object members are sorted by the UTF-16 code
/// units of their names. Strings escape only the characters RFC 8785 section
/// 3.2.2.2 lists, and write every other character literally. Numbers use the
/// ECMAScript `Number.prototype.toString` form of the IEEE 754 double.
///
/// Like ``SHA256``, this type is `package`-scoped so it does not widen any
/// library product's public surface.
package enum CanonicalJSON {
    package enum Error: Swift.Error, Equatable {
        /// RFC 8785 cannot represent NaN or an infinity.
        case nonFiniteNumber
    }

    /// The canonical text of `value`.
    package static func string(_ value: GnosticJSONValue) throws -> String {
        var output = ""
        try write(value, to: &output)
        return output
    }

    /// The canonical UTF-8 bytes of `value`.
    package static func bytes(_ value: GnosticJSONValue) throws -> [UInt8] {
        Array(try string(value).utf8)
    }

    private static func write(_ value: GnosticJSONValue, to output: inout String) throws {
        switch value {
        case .null:
            output += "null"
        case let .boolean(flag):
            output += flag ? "true" : "false"
        case let .string(text):
            writeString(text, to: &output)
        case let .integer(number):
            // Integers within the double's exact range keep their digits. A
            // larger one takes the double's ES6 form, as RFC 8785 requires.
            if number.magnitude <= UInt64(1) << 53 {
                output += String(number)
            } else {
                output += try Self.number(Double(number))
            }
        case let .unsignedInteger(number):
            output += number <= UInt64(1) << 53 ? String(number) : try Self.number(Double(number))
        case let .number(number):
            output += try Self.number(number)
        case let .array(elements):
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                try write(element, to: &output)
            }
            output += "]"
        case let .dictionary(members):
            output += "{"
            // RFC 8785 section 3.2.3: sort by UTF-16 code units, not by
            // Unicode scalars, so a supplementary character sorts before
            // U+FB33.
            let names = members.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (index, name) in names.enumerated() {
                if index > 0 { output += "," }
                writeString(name, to: &output)
                output += ":"
                try write(members[name] ?? .null, to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0C: output += "\\f"
            case 0x0D: output += "\\r"
            case 0x00..<0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    /// ECMAScript `Number::toString` (ECMA-262 section 6.1.6.1.20) for a finite
    /// double. Swift's description already yields the shortest digits that
    /// round-trip, which is the digit string ECMAScript selects. This function
    /// re-lays those digits out in the ECMAScript form.
    package static func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw Error.nonFiniteNumber }
        if value == 0 { return "0" }
        let negative = value < 0
        let (digits, pointPosition) = shortestDigits(of: abs(value))
        let digitCount = digits.count
        // The value is 0.<digits> x 10^pointPosition.
        let n = pointPosition
        var text: String
        if digitCount <= n, n <= 21 {
            text = digits + String(repeating: "0", count: n - digitCount)
        } else if 0 < n, n <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: n)
            text = digits[..<split] + "." + digits[split...]
        } else if -6 < n, n <= 0 {
            text = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let exponent = n - 1
            let sign = exponent < 0 ? "-" : "+"
            let head = digits.prefix(1)
            let tail = digits.dropFirst()
            text = tail.isEmpty ? String(head) : head + "." + tail
            text += "e" + sign + String(abs(exponent))
        }
        return negative ? "-" + text : text
    }

    /// The shortest round-trip decimal digits of a positive finite double, and
    /// the position of the decimal point relative to them.
    private static func shortestDigits(of value: Double) -> (digits: String, pointPosition: Int) {
        let description = "\(value)"
        let parts = description.lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = String(parts[0])
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let halves = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = String(halves[0])
        let fractionPart = halves.count > 1 ? String(halves[1]) : ""
        var digits = integerPart + fractionPart
        var pointPosition = integerPart.count + exponent
        while digits.hasPrefix("0") {
            digits.removeFirst()
            pointPosition -= 1
        }
        while digits.hasSuffix("0") { digits.removeLast() }
        return (digits, pointPosition)
    }
}
