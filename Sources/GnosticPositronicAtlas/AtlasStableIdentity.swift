// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Host-assigned durable identity for Atlas integration output.
///
/// Integrator output is untrusted. When an integration proposes a new accepted
/// object, the host does not trust the identity the integrator chose. It
/// derives a stable, Ascendant-scoped identity from the object's semantic
/// address instead. Re-integrating the same semantic address always produces
/// the same identity, and two Ascendants can never collide.
///
/// The derivation is a name-based UUID over a domain-separated canonical
/// string (SHA-256 reduced to 128 bits through the RFC 4122 version 5 and
/// variant fields). It is deterministic across processes and runs.
public struct AtlasHostIdentity: Sendable {
    /// The domain that separates one kind of host identity from another.
    public enum Namespace: String, Sendable {
        /// An accepted semantic item.
        case item
        /// A scoped conflict.
        case conflict
        /// An advisory directive.
        case directive
    }

    /// Creates the host identity for an accepted item addressed by its key.
    public static func itemID(ascendantID: UUID, key: String) -> AtlasItemID {
        AtlasItemID(rawValue: uuid(namespace: .item, ascendantID: ascendantID, payload: key))
    }

    /// Creates the host identity for an advisory directive addressed by its
    /// optional target Shard and key.
    public static func directiveID(
        ascendantID: UUID,
        shardID: AscendantShardID?,
        key: String
    ) -> AtlasDirectiveID {
        let scope = shardID?.rawValue.uuidString.lowercased() ?? ""
        return AtlasDirectiveID(rawValue: uuid(
            namespace: .directive,
            ascendantID: ascendantID,
            payload: "\(scope)/\(key)"
        ))
    }

    /// Creates the host identity for a scoped conflict addressed by its Shard
    /// and referenced item identities.
    public static func conflictID(
        ascendantID: UUID,
        shardID: AscendantShardID,
        itemIDs: [AtlasItemID]
    ) -> AtlasConflictID {
        let itemPart = Array(Set(itemIDs)).sorted().map { $0.rawValue.uuidString.lowercased() }.joined(separator: ",")
        return AtlasConflictID(rawValue: uuid(
            namespace: .conflict,
            ascendantID: ascendantID,
            payload: "\(shardID.rawValue.uuidString.lowercased())/\(itemPart)"
        ))
    }

    /// Creates the deterministic host identity for the patch produced from one
    /// capture. A repeated flush of the same capture reuses the identity, so
    /// the store can report an idempotent commit instead of double-applying.
    public static func patchID(ascendantID: UUID, captureID: AtlasCaptureID) -> AtlasPatchID {
        AtlasPatchID("atlas-patch/\(ascendantID.uuidString.lowercased())/\(captureID.rawValue)")
    }

    private static func uuid(namespace: Namespace, ascendantID: UUID, payload: String) -> UUID {
        let canonical = "atlas/\(namespace.rawValue)/\(ascendantID.uuidString.lowercased())/\(payload)"
        var digest = AtlasSHA256.digest(canonical)
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// A small, dependency-free SHA-256 used only for deterministic identity
/// derivation inside Atlas. The package manifest is not widened for a naming
/// function, and the digest stays collision-resistant.
enum AtlasSHA256 {
    static func digest(_ string: String) -> [UInt8] {
        digest(Array(string.utf8))
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var hash: [UInt32] = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
        ]
        let constants: [UInt32] = [
            0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
            0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
            0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
            0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
            0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
            0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
            0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
            0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
            0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
            0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
            0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
            0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
            0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
            0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
            0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
            0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
        ]

        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < data.count {
            for index in 0..<16 {
                let base = offset + index * 4
                schedule[index] = (UInt32(data[base]) << 24)
                    | (UInt32(data[base + 1]) << 16)
                    | (UInt32(data[base + 2]) << 8)
                    | UInt32(data[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], 7)
                    ^ rotateRight(schedule[index - 15], 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], 17)
                    ^ rotateRight(schedule[index - 2], 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }

            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ schedule[index]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
            offset += 64
        }

        var output = [UInt8]()
        output.reserveCapacity(32)
        for value in hash {
            output.append(UInt8((value >> 24) & 0xFF))
            output.append(UInt8((value >> 16) & 0xFF))
            output.append(UInt8((value >> 8) & 0xFF))
            output.append(UInt8(value & 0xFF))
        }
        return output
    }

    private static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
