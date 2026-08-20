// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Keeps bounded identified-turn updates for one serve lifetime. It never
/// stores prompt text or tool arguments beyond the bounded update payload.
public actor AscendantTurnUpdateStore {
    public struct Event: Codable, Sendable, Equatable {
        public let protocolMajor: Int
        public let timelineID: UUID
        public let clientTurnID: String
        public let update: AscendantTurnUpdate

        public init(protocolMajor: Int = GnosticProtocol.currentMajor, timelineID: UUID, clientTurnID: String, update: AscendantTurnUpdate) {
            self.protocolMajor = protocolMajor
            self.timelineID = timelineID
            self.clientTurnID = clientTurnID
            self.update = update
        }

        private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, clientTurnID, update }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
            timelineID = try container.decode(UUID.self, forKey: .timelineID)
            clientTurnID = try container.decode(String.self, forKey: .clientTurnID)
            update = try container.decode(AscendantTurnUpdate.self, forKey: .update)
        }
    }

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
    private let eventStream: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    public init(maxEvents: Int = 1_024, maxBytes: Int = 1_048_576) {
        // Compacted replay needs room for both a snapshot and the newest (often
        // terminal) update.
        self.maxEvents = max(2, maxEvents)
        self.maxBytes = max(256, maxBytes)
        (eventStream, eventContinuation) = AsyncStream<Event>.makeStream()
    }

    func events() -> AsyncStream<Event> { eventStream }

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
        toolState: AscendantToolState? = nil,
        permissionState: AscendantPermissionState? = nil,
        terminal: Bool = false,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) -> AscendantTurnUpdate {
        let key = Key(timelineID: timelineID, clientTurnID: clientTurnID)
        var entry = entries[key] ?? Entry(updates: [], nextSequence: 1, bytes: 0, terminal: false, compacted: false, messageDigest: nil)
        let update = Self.bounded(
            AscendantTurnUpdate(
                sequence: entry.nextSequence,
                kind: kind,
                text: text,
                toolState: toolState,
                permissionState: permissionState,
                terminal: terminal,
                protocolMajor: protocolMajor
            ),
            maxBytes: maxBytes / 2
        )
        entry.nextSequence += 1
        entry.updates.append(update)
        entry.bytes += Self.encodedSize(update)
        entry.terminal = entry.terminal || terminal

        if entry.updates.count > maxEvents || entry.bytes > maxBytes {
            var snapshotText = ""
            var snapshotToolStates: [AscendantToolState] = []
            var snapshotPermissionStates: [AscendantPermissionState] = []
            var snapshotSequence = 0
            // Reserve half of the byte budget for the accumulated snapshot.
            while entry.updates.count >= maxEvents || entry.bytes > maxBytes / 2 {
                guard entry.updates.count > 1 else { break }
                let removed = entry.updates.removeFirst()
                entry.bytes -= Self.encodedSize(removed)
                snapshotSequence = max(snapshotSequence, removed.sequence)
                if removed.kind == "assistant_text" || removed.kind == "assistant_text_snapshot" {
                    snapshotText += removed.text ?? ""
                }
                if let toolState = removed.toolState {
                    Self.upsert(toolState, into: &snapshotToolStates)
                }
                for toolState in removed.toolStates {
                    Self.upsert(toolState, into: &snapshotToolStates)
                }
                if let permissionState = removed.permissionState {
                    Self.upsert(permissionState, into: &snapshotPermissionStates)
                }
                for permissionState in removed.permissionStates {
                    Self.upsert(permissionState, into: &snapshotPermissionStates)
                }
                entry.compacted = true
            }
            if !snapshotText.isEmpty || !snapshotToolStates.isEmpty || !snapshotPermissionStates.isEmpty {
                let snapshot = Self.bounded(AscendantTurnUpdate(
                    sequence: snapshotSequence,
                    kind: "assistant_text_snapshot",
                    text: snapshotText.isEmpty ? nil : snapshotText,
                    toolStates: snapshotToolStates,
                    permissionStates: snapshotPermissionStates
                ), maxBytes: max(1, maxBytes - entry.bytes))
                entry.updates.insert(snapshot, at: 0)
                entry.bytes += Self.encodedSize(snapshot)
            }
        }
        entries[key] = entry
        eventContinuation.yield(Event(protocolMajor: protocolMajor, timelineID: timelineID, clientTurnID: clientTurnID, update: update))
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

    private static func bounded(_ update: AscendantTurnUpdate, maxBytes: Int) -> AscendantTurnUpdate {
        var text = update.text
        var toolStates = update.toolStates
        var permissionStates = update.permissionStates
        var candidate = update
        while encodedSize(candidate) > maxBytes, let current = text, !current.isEmpty {
            text = String(current.prefix(current.count / 2))
            candidate = AscendantTurnUpdate(
                sequence: update.sequence,
                kind: update.kind,
                text: text,
                toolState: update.toolState,
                toolStates: toolStates,
                permissionState: update.permissionState,
                permissionStates: permissionStates,
                terminal: update.terminal
            )
        }
        while encodedSize(candidate) > maxBytes, !toolStates.isEmpty {
            toolStates.removeFirst()
            candidate = AscendantTurnUpdate(
                sequence: update.sequence,
                kind: update.kind,
                text: text,
                toolState: update.toolState,
                toolStates: toolStates,
                permissionState: update.permissionState,
                permissionStates: permissionStates,
                terminal: update.terminal
            )
        }
        while encodedSize(candidate) > maxBytes, !permissionStates.isEmpty {
            permissionStates.removeFirst()
            candidate = AscendantTurnUpdate(
                sequence: update.sequence,
                kind: update.kind,
                text: text,
                toolState: update.toolState,
                toolStates: toolStates,
                permissionState: update.permissionState,
                permissionStates: permissionStates,
                terminal: update.terminal
            )
        }
        return candidate
    }

    private static func upsert(_ state: AscendantToolState, into states: inout [AscendantToolState]) {
        if let index = states.firstIndex(where: { $0.toolCallID == state.toolCallID }) {
            states[index] = state
        } else {
            states.append(state)
        }
    }

    private static func upsert(
        _ state: AscendantPermissionState,
        into states: inout [AscendantPermissionState]
    ) {
        if let index = states.firstIndex(where: { $0.correlationID == state.correlationID }) {
            states[index] = state
        } else {
            states.append(state)
        }
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
