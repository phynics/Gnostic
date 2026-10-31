// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The digest that identifies a Turn's prompt at admission (ADR 0021 Turn
/// semantics).
///
/// It is the SHA-256 of the RFC 8785 canonical form of the document
/// `{"acpVersionTag": <tag>, "prompt": <content blocks>}`. Binding the ACP
/// version tag into the digest means a prompt admitted under one recorded
/// revision of the ACP v2 schema never matches the same text under another.
package enum TurnAdmissionDigest {
    /// The lowercase hexadecimal digest of `prompt` under `acpVersionTag`.
    package static func hex(prompt: [ACPContentBlock], acpVersionTag: String) throws -> String {
        let content = try JSONDecoder().decode(GnosticJSONValue.self, from: JSONEncoder().encode(prompt))
        let document = GnosticJSONValue.dictionary([
            "acpVersionTag": .string(acpVersionTag),
            "prompt": content,
        ])
        return SHA256.hexDigest(try CanonicalJSON.bytes(document))
    }
}
