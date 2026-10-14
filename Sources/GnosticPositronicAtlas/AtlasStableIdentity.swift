// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// Host-assigned durable identity for Atlas integration output.
///
/// Integrator output is untrusted. When an integration proposes a new accepted
/// object, the host does not trust the identity the integrator chose. It
/// derives a stable, Ascendant-scoped identity from the object's semantic
/// address instead. Re-integrating the same semantic address always produces
/// the same identity, and two Ascendants can never collide.
///
/// The derivation is a name-based UUID over a domain-separated canonical
/// string (the package's one SHA-256 reduced to 128 bits through the RFC 4122
/// version 5 and variant fields). It is deterministic across processes and
/// runs.
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
        var digest = SHA256.digest(canonical)
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
