// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Measures how deeply a JSON text nests, without decoding it.
///
/// A recursive decoder spends stack for each level of nesting. A Runtime writes
/// the text, so a hostile or faulty Runtime picks the depth, and a small thread
/// stack such as a macOS secondary thread's 512 KiB can overflow and end the
/// host process. Gnostic bounds the depth before any recursive decode sees the
/// text. The scan itself is a single loop and uses constant stack.
enum JSONNesting {
    /// The deepest nesting that Gnostic decodes in a message from a Runtime.
    ///
    /// A `session/update` frame needs three levels for its envelope, `params`,
    /// and `update`. 128 leaves a Runtime 125 levels of its own, and decoding
    /// that much fits a 512 KiB thread stack with room to spare.
    static let maximumDecodedDepth = 128

    /// The deepest nesting of `[` and `{` in `bytes`, counting only brackets
    /// outside JSON strings.
    ///
    /// The scan stops as soon as the depth exceeds `limit` and returns that
    /// depth, so it never reads more of a hostile text than it has to. It does
    /// not check that the text is valid JSON, and an unmatched closing bracket
    /// does not lower the depth below zero.
    static func deepest(in bytes: some Sequence<UInt8>, stoppingAbove limit: Int = .max) -> Int {
        var depth = 0
        var deepest = 0
        var insideString = false
        var escaped = false
        for byte in bytes {
            if insideString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    insideString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                insideString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > deepest {
                    deepest = depth
                    if deepest > limit { return deepest }
                }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return deepest
    }

    /// Whether `bytes` nests deeper than `maximumDecodedDepth`.
    static func exceedsMaximumDecodedDepth(_ bytes: some Sequence<UInt8>) -> Bool {
        deepest(in: bytes, stoppingAbove: maximumDecodedDepth) > maximumDecodedDepth
    }
}
