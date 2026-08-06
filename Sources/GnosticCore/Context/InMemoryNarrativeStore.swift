// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// An actor-isolated, append-only narrative store kept entirely in memory.
///
/// Duplicate stable identifiers are rejected by throwing
/// `NarrativeStoreError.duplicateEntryID`. Read operations return value copies,
/// and no mutation or deletion surface is exposed.
public actor InMemoryNarrativeStore: NarrativeStore {
    private var entriesByID: [NarrativeEntryID: NarrativeEntry] = [:]
    private var orderedIDs: [NarrativeEntryID] = []

    /// Creates an empty store.
    public init() {}

    /// Appends an entry, rejecting an already-stored stable identifier.
    public func append(_ entry: NarrativeEntry) async throws {
        guard entriesByID[entry.id] == nil else {
            throw NarrativeStoreError.duplicateEntryID(entry.id)
        }
        entriesByID[entry.id] = entry
        orderedIDs.append(entry.id)
    }

    /// Returns a stored entry by its stable identifier.
    public func entry(id: NarrativeEntryID) async -> NarrativeEntry? {
        entriesByID[id]
    }

    /// Returns every stored entry in append order.
    public func snapshot() async -> [NarrativeEntry] {
        orderedIDs.compactMap { entriesByID[$0] }
    }
}