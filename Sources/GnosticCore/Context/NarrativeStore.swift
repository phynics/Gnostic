// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Failures produced by an append-only narrative store.
public enum NarrativeStoreError: Error, Sendable, Equatable, LocalizedError {
    /// Appending an entry whose stable identifier already exists.
    case duplicateEntryID(NarrativeEntryID)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .duplicateEntryID(id):
            return "A narrative entry with identifier \(id.rawValue.uuidString) already exists."
        }
    }

    /// A machine-readable reason label for diagnostics.
    public var reasonCode: String {
        switch self {
        case .duplicateEntryID:
            return "duplicateEntryID"
        }
    }
}

/// The actor-safe boundary for an append-only narrative store.
///
/// Entries are immutable and may only be appended. Lookup and snapshot reads
/// return value copies, so stored entries cannot be mutated or deleted through
/// this interface.
public protocol NarrativeStore: Sendable, AnyObject {
    /// Appends an entry, rejecting an already-stored stable identifier.
    ///
    /// - Parameter entry: The immutable entry to append.
    /// - Throws: `NarrativeStoreError.duplicateEntryID` if the identifier exists.
    func append(_ entry: NarrativeEntry) async throws

    /// Returns a stored entry by its stable identifier.
    ///
    /// - Parameter id: The entry identifier.
    /// - Returns: The stored entry, if present.
    func entry(id: NarrativeEntryID) async -> NarrativeEntry?

    /// Returns every stored entry in append order.
    func snapshot() async -> [NarrativeEntry]
}