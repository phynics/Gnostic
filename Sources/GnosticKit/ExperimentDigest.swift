// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// The kit's public entry point for stable experiment identity.
///
/// The kit must produce the same artifact and case-set identity on every host
/// and on every run. The digest itself lives once in `GnosticCore` as
/// `SHA256`; this type keeps the kit's published spelling and delegates to it,
/// so the kit, the context module, and Atlas cannot drift onto different
/// implementations.
public enum ExperimentDigest {
    /// Returns the lowercase hexadecimal SHA-256 digest of `bytes`.
    public static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hexDigest(bytes)
    }

    /// Returns the lowercase hexadecimal SHA-256 digest of the UTF-8 encoding of `string`.
    public static func sha256Hex(_ string: String) -> String {
        SHA256.hexDigest(string)
    }
}
