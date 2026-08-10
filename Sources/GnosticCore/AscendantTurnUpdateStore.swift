// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A replayable, transport-neutral update emitted for an identified Ascendant
/// turn. The ACP adapter maps these values to `session/update` notifications.
public struct AscendantTurnUpdate: Codable, Sendable, Equatable {
    public let sequence: Int
    public let kind: String
    public let text: String?
    public let terminal: Bool

    public init(sequence: Int, kind: String, text: String? = nil, terminal: Bool = false) {
        self.sequence = sequence
        self.kind = kind
        self.text = text
        self.terminal = terminal
    }
}

public struct AscendantTurnReplay: Codable, Sendable, Equatable {
    public let updates: [AscendantTurnUpdate]
    public let compacted: Bool
    public let terminal: Bool
    public let conflict: Bool

    public init(updates: [AscendantTurnUpdate], compacted: Bool, terminal: Bool, conflict: Bool = false) {
        self.updates = updates
        self.compacted = compacted
        self.terminal = terminal
        self.conflict = conflict
    }

    private enum CodingKeys: String, CodingKey {
        case updates, compacted, terminal, conflict
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updates = try container.decode([AscendantTurnUpdate].self, forKey: .updates)
        compacted = try container.decode(Bool.self, forKey: .compacted)
        terminal = try container.decode(Bool.self, forKey: .terminal)
        conflict = try container.decodeIfPresent(Bool.self, forKey: .conflict) ?? false
    }
}

/// Keeps bounded identified-turn updates for one serve lifetime. It never
/// stores prompt text or tool arguments beyond the bounded update payload.
public actor AscendantTurnUpdateStore {
    private struct Key: Hashable, Sendable {
        let timelineID: UUID
        let clientTurnID: String
    }

    private struct Entry: Sendable {
        var updates: [AscendantTurnUpdate]
        var nextSequence: Int
        var bytes: Int
        var terminal: Bool
        var compacted: Bool
        var messageDigest: UInt64?
    }

    private let maxEvents: Int
    private let maxBytes: Int
    private var entries: [Key: Entry] = [:]

    public init(maxEvents: Int = 1_024, maxBytes: Int = 1_048_576) {
        // Compacted replay needs room for both a snapshot and the newest (often
        // terminal) update.
        self.maxEvents = max(2, maxEvents)
        self.maxBytes = max(1, maxBytes)
    }

    public func start(timelineID: UUID, clientTurnID: String, message: String? = nil) {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID)
        guard entries[key] == nil else { return }
        entries[key] = Entry(
            updates: [], nextSequence: 1, bytes: 0, terminal: false, compacted: false,
            messageDigest: message.map { Self.messageDigest($0) }
        )
    }

    @discardableResult
    public func append(
        timelineID: UUID,
        clientTurnID: String,
        kind: String,
        text: String? = nil,
        terminal: Bool = false
    ) -> AscendantTurnUpdate {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID)
        var entry = entries[key] ?? Entry(updates: [], nextSequence: 1, bytes: 0, terminal: false, compacted: false, messageDigest: nil)
        let update = AscendantTurnUpdate(sequence: entry.nextSequence, kind: kind, text: text, terminal: terminal)
        entry.nextSequence += 1
        entry.updates.append(update)
        entry.bytes += Self.encodedSize(update)
        entry.terminal = entry.terminal || terminal

        if entry.updates.count > maxEvents || entry.bytes > maxBytes {
            var snapshotText = ""
            var snapshotSequence = 0
            while entry.updates.count >= maxEvents || entry.bytes > maxBytes {
                guard entry.updates.count > 1 else { break }
                let removed = entry.updates.removeFirst()
                entry.bytes -= Self.encodedSize(removed)
                snapshotSequence = max(snapshotSequence, removed.sequence)
                if removed.kind == "assistant_text" || removed.kind == "assistant_text_snapshot" {
                    snapshotText += removed.text ?? ""
                }
                entry.compacted = true
            }
            if !snapshotText.isEmpty {
                let snapshot = AscendantTurnUpdate(
                    sequence: snapshotSequence,
                    kind: "assistant_text_snapshot",
                    text: snapshotText
                )
                entry.updates.insert(snapshot, at: 0)
                entry.bytes += Self.encodedSize(snapshot)
            }
        }
        entries[key] = entry
        return update
    }

    public func replay(timelineID: UUID, clientTurnID: String, message: String? = nil, afterSequence: Int = 0) -> AscendantTurnReplay {
        guard let entry = entries[Key(timelineID: timelineID, clientTurnID: clientTurnID)] else {
            return AscendantTurnReplay(updates: [], compacted: false, terminal: false)
        }
        if let message, let digest = entry.messageDigest, digest != Self.messageDigest(message) {
            return AscendantTurnReplay(updates: [], compacted: false, terminal: true, conflict: true)
        }
        return AscendantTurnReplay(
            updates: entry.updates.filter { $0.sequence > afterSequence },
            compacted: entry.compacted && afterSequence < (entry.updates.first?.sequence ?? 0),
            terminal: entry.terminal
        )
    }

    private static func encodedSize(_ update: AscendantTurnUpdate) -> Int {
        (try? JSONEncoder().encode(update).count) ?? 0
    }

    private static func messageDigest(_ message: String) -> UInt64 {
        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in message.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return digest
    }
}
