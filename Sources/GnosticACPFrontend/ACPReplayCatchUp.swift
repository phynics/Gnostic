// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticCore

/// What a prompt that missed live updates may take from replay. Replay holds
/// history, so it can repeat what a client saw and name requests already settled.
enum ACPReplayCatchUp {
    /// Permission requests the client must not be asked about. A request
    /// resolved later in `updates` is settled. Once the Turn has ended, none
    /// can still be answered.
    static func permissionsToSkip(in updates: [AscendantTurnUpdate], turnEnded: Bool) -> Set<String> {
        var skipped: Set<String> = []
        for update in updates {
            for state in [update.permissionState].compactMap({ $0 }) + update.permissionStates
            where turnEnded || state.status != "pending" {
                skipped.insert(state.correlationID)
            }
        }
        return skipped
    }

    /// `update` without text the client already holds, or `nil` when nothing is left.
    ///
    /// A retention snapshot holds the Turn's text from its start, so a client
    /// that received part of it must not append that part again. When the
    /// snapshot is cut before the point the client reached, only the marker is
    /// new: it says text after that point was lost.
    ///
    /// A prompt never delivers past a gap, so what the client holds is always a
    /// prefix of the snapshot and the byte offset falls on a scalar boundary.
    static func removingDeliveredText(
        from update: AscendantTurnUpdate,
        deliveredTextBytes: Int
    ) -> AscendantTurnUpdate? {
        guard deliveredTextBytes > 0,
              update.updateKind == .assistantTextSnapshot,
              let text = update.text else { return update }
        let marker = AscendantTurnUpdate.truncationMarker
        let isCut = text.hasSuffix(marker)
        let bodyBytes = text.utf8.count - (isCut ? marker.utf8.count : 0)
        let remaining: String? = if deliveredTextBytes < bodyBytes {
            String(decoding: text.utf8.dropFirst(deliveredTextBytes), as: UTF8.self)
        } else {
            isCut ? marker : nil
        }
        let hasStates = !update.toolStates.isEmpty || !update.permissionStates.isEmpty
        guard remaining != nil || hasStates else { return nil }
        return AscendantTurnUpdate(
            sequence: update.sequence,
            kind: update.kind,
            text: remaining,
            toolStates: update.toolStates,
            permissionStates: update.permissionStates
        )
    }
}
