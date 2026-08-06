// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The outcome of a narrative retrieval: an ordered, bounded selection, the
/// reconstructed open threads, and the authoritative current-state packet.
public struct NarrativeRetrievalResult: Sendable {
    /// The ranked, bounded narrative entries relevant to the query.
    public let rankedEntries: [NarrativeEntry]
    /// Active open threads reconstructed solely from append-only updates.
    public let openThreads: [OpenThreadState]
    /// The textual current-state packet.
    public let currentStatePacket: CurrentStatePacket

    /// Creates a retrieval result.
    public init(
        rankedEntries: [NarrativeEntry],
        openThreads: [OpenThreadState],
        currentStatePacket: CurrentStatePacket
    ) {
        self.rankedEntries = rankedEntries
        self.openThreads = openThreads
        self.currentStatePacket = currentStatePacket
    }
}

/// Selects compact, deterministic long-horizon context and reconstructs open
/// threads from append-only entries.
///
/// Ranking is deterministic and bounded: exact shared identifiers outrank
/// lexical similarity, then open-thread state, importance, confidence, and
/// temporal proximity. Resolved and superseded entries are excluded from the
/// current reconstruction but remain available through explicit history
/// queries. Empty or failed retrieval never blocks a turn.
public struct NarrativeRetrieval: Sendable {
    private let store: any NarrativeStore
    private let defaultStateFallback: @Sendable () -> CurrentStatePacket

    /// Creates a retrieval engine over an append-only store.
    ///
    /// - Parameters:
    ///   - store: The source of narrative entries.
    ///   - defaultStateFallback: Produces the authoritative current-state
    ///     packet when a caller does not supply an overriding one.
    public init(
        store: any NarrativeStore,
        defaultStateFallback: @escaping @Sendable () -> CurrentStatePacket = {
            CurrentStatePacket(authorativeState: "No authoritative state supplied.", isAuthoritative: true)
        }
    ) {
        self.store = store
        self.defaultStateFallback = defaultStateFallback
    }

    /// Retrieves current narrative context for a turn.
    ///
    /// - Parameters:
    ///   - query: The retrieval query.
    ///   - overridingState: An optional authoritative current-state packet that
    ///     outranks conflicting narrative interpretation.
    /// - Returns: A bounded, ranked selection plus reconstructed open threads.
    public func retrieve(
        query: NarrativeRetrievalQuery,
        overridingState: CurrentStatePacket? = nil
    ) async -> NarrativeRetrievalResult {
        let all = await store.snapshot()
        let packet = overridingState ?? defaultStateFallback()
        return Self.compose(entries: all, query: query, packet: packet)
    }

    /// Returns an explicit history selection, including resolved and
    /// superseded entries, in append order (newest first), bounded by ``limit``.
    public func history(limit: Int) async -> [NarrativeEntry] {
        Array((await store.snapshot()).reversed().prefix(limit))
    }

    private static func compose(
        entries: [NarrativeEntry],
        query: NarrativeRetrievalQuery,
        packet: CurrentStatePacket
    ) -> NarrativeRetrievalResult {
        let queryTokens = tokenSet(query.currentUserText)
        let queryIdentifiers: Set<String> =
            Set(query.timelineIDs.map(\.uuidString))
            .union(query.workspaceIDs.map(\.uuidString))
            .union(query.filePaths)
            .union(query.taskIDs)
            .union(query.toolIDs)

        var effective: [NarrativeEntry] = []
        var superseded: Set<NarrativeEntryID> = []
        for entry in entries {
            superseded.formUnion(entry.supersededIDs)
        }

        var scored: [(entry: NarrativeEntry, score: Double)] = []
        for entry in entries where !superseded.contains(entry.id) {
            scored.append((entry, score(entry, tokens: queryTokens, identifiers: queryIdentifiers)))
        }
        scored.sort(by: {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.recordedAt != $1.entry.recordedAt { return $0.entry.recordedAt > $1.entry.recordedAt }
            return $0.entry.id.rawValue.uuidString > $1.entry.id.rawValue.uuidString
        })

        effective = scored.prefix(query.limit).map(\.entry)

        let openThreads = reconstructOpenThreads(from: entries, superseded: superseded)

        return NarrativeRetrievalResult(
            rankedEntries: effective,
            openThreads: openThreads,
            currentStatePacket: packet
        )
    }

    private static func score(
        _ entry: NarrativeEntry,
        tokens: Set<String>,
        identifiers: Set<String>
    ) -> Double {
        let sourceIdentifiers: Set<String> =
            Set(entry.source.workspaceIDs.map(\.uuidString))
            .union(entry.source.toolIDs)
            .union(entry.source.correlationIDs)
            .union(entry.source.filePaths)
        let identifierOverlap = sourceIdentifiers.intersection(identifiers)

        let entryTokens = tokenSet(entry.observation + " " + entry.interpretation + " " + (entry.lesson?.summary ?? ""))
        let keywordOverlap = entryTokens.intersection(tokens)

        var score: Double = Double(identifierOverlap.count) * 100.0
            + Double(keywordOverlap.count) * 10.0
            + entry.importance * 5.0
            + entry.confidence * 2.0
        if entry.openThread?.status == .active {
            score += 8.0
        }
        return score
    }

    private static func reconstructOpenThreads(
        from entries: [NarrativeEntry],
        superseded: Set<NarrativeEntryID>
    ) -> [OpenThreadState] {
        let openThreadEntries = entries.filter {
            !superseded.contains($0.id)
                && $0.openThread?.status == .active
        }
        var newestBySummary: [String: OpenThreadState] = [:]
        for entry in openThreadEntries.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            if let thread = entry.openThread {
                newestBySummary[thread.summary] = thread
            }
        }
        return newestBySummary.values.sorted { $0.summary < $1.summary }
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }
}