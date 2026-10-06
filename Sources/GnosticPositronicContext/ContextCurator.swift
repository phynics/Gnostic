// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Turns one immutable episode into a structured semantic proposal.
///
/// The curator sees only the episode, the active carry state, and the
/// descriptor. It has no store authority, so it cannot commit, enlarge a
/// budget, or change a version. The host validates and commits what the curator
/// proposes (GNO-CTX-004).
public protocol ContextCurator: Sendable {
    /// A stable version label for the curator.
    ///
    /// The label is provenance, not identity. It never enters a node ID.
    var version: String { get }

    /// Produces a structured proposal for one episode.
    ///
    /// - Parameters:
    ///   - episode: The immutable episode.
    ///   - activeCarry: The carry state already accepted for the Timeline.
    ///   - descriptor: The host-owned bounds.
    /// - Returns: The proposal.
    /// - Throws: ``ContextError/malformedProposal`` when the curator cannot
    ///   produce a valid proposal shape.
    func propose(
        episode: ContextEpisode,
        activeCarry: ContextCarryState,
        descriptor: ContextDescriptor
    ) async throws -> ContextProposal
}

/// Replays a fixture transcript episode by episode.
///
/// The replay is the offline stand-in for incremental curation. It produces one
/// leaf proposal per episode and threads the accumulated carry into the next
/// episode, so the curator sees what the Timeline already carries.
///
/// The replay never commits. It returns proposals; GNO-CTX-004 validates and
/// commits them. A curator failure throws, so no partial result escapes.
public struct ContextEpisodeReplay: Sendable {
    /// The Timeline the replay reports.
    public let timelineID: String
    /// The number of messages in one episode.
    public let episodeSize: Int

    /// Creates a replay.
    ///
    /// - Parameters:
    ///   - timelineID: The Timeline the replay reports.
    ///   - episodeSize: The number of messages in one episode.
    public init(timelineID: String, episodeSize: Int = 8) {
        self.timelineID = timelineID
        self.episodeSize = max(1, episodeSize)
    }

    /// Splits a transcript into chronological episodes.
    ///
    /// - Parameter transcript: The transcript.
    /// - Returns: The episodes, in order.
    public func episodes(from transcript: ContextTranscript) -> [ContextEpisode] {
        let messages = transcript.turns.map {
            ContextMessage(id: ContextMessage.id(forTurnIndex: $0.index), role: $0.role, text: $0.text)
        }
        return stride(from: 0, to: messages.count, by: episodeSize).map { start in
            let end = min(start + episodeSize, messages.count)
            return ContextEpisode(timelineID: timelineID, messages: Array(messages[start..<end]))
        }
    }

    /// Replays every episode through the curator.
    ///
    /// - Parameters:
    ///   - transcript: The transcript.
    ///   - descriptor: The host-owned bounds.
    ///   - curator: The curator.
    /// - Returns: One leaf proposal per episode, in order.
    /// - Throws: A `ContextError` when a curator fails.
    public func replay(
        transcript: ContextTranscript,
        descriptor: ContextDescriptor,
        curator: any ContextCurator
    ) async throws -> [ContextLeafProposal] {
        var active = ContextCarryState()
        var leaves: [ContextLeafProposal] = []
        for episode in episodes(from: transcript) {
            let proposal = try await curator.propose(
                episode: episode,
                activeCarry: active,
                descriptor: descriptor
            )
            leaves.append(ContextLeafProposal(episode: episode, proposal: proposal))
            // Simple accumulation. GNO-CTX-005 replaces this with the
            // deterministic carry reducer.
            active = ContextCarryState(items: active.items + proposal.items)
        }
        return leaves
    }
}
