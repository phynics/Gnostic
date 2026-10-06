// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticKit

/// Stable hashing for context identity.
///
/// The experiment must produce the same identity on every host, so it uses the
/// kit's dependency-free SHA-256 for digests and a small FNV-1a for the
/// planner's `UInt64` node fingerprint.
public enum ContextHashing {
    /// Returns the canonical digest of ordered parts.
    ///
    /// - Parameter parts: The parts to hash, in order.
    /// - Returns: The lowercase hexadecimal SHA-256 digest.
    public static func digest(_ parts: [String]) -> String {
        ExperimentDigest.sha256Hex(parts.joined(separator: "\u{1F}"))
    }

    /// Returns an FNV-1a 64-bit fingerprint of `value`.
    ///
    /// - Parameter value: The text to fingerprint.
    /// - Returns: The fingerprint.
    public static func fnv1a(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Zero-pads `index` so lexicographic path order matches chronological order.
    ///
    /// - Parameter index: The turn index.
    /// - Returns: The padded component.
    public static func pathComponent(_ index: Int) -> String {
        String(format: "turn-%06d", index)
    }
}
