// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The lifecycle state of one Timeline's curation partition.
public enum ContextCurationState: String, Sendable, Equatable, CaseIterable {
    /// No curation is running and no episode is queued.
    case idle
    /// One curation is running and no episode is queued.
    case curating
    /// One curation is running and at least one episode is queued.
    case pending
    /// The coordinator is shutting down; new work is refused.
    case stopping
}

/// Payload-free counters for one Timeline's curation partition.
///
/// The diagnostics hold counts and the last structured error only. They never
/// hold conversation text, a message ID, or a proposal body, so reporting them
/// cannot leak content.
public struct ContextCurationDiagnostics: Sendable, Equatable {
    /// The episodes accepted for curation.
    public internal(set) var submitted = 0
    /// The curation requests the coordinator started.
    public internal(set) var started = 0
    /// The proposals the host accepted.
    public internal(set) var accepted = 0
    /// The proposals a curator or the host rejected.
    public internal(set) var rejected = 0
    /// The curation calls that failed for a reason other than a rejection.
    public internal(set) var failures = 0
    /// The submissions folded into a queued episode on overflow.
    public internal(set) var overflowMerges = 0
    /// The submissions refused because the coordinator was stopping.
    public internal(set) var rejectedAfterShutdown = 0
    /// The last structured error the coordinator contained, when any.
    public internal(set) var lastError: ContextError?

    /// Creates zeroed diagnostics.
    public init() {}
}

/// Runs semantic curation off the Turn path, one curation per Timeline.
///
/// The coordinator is the off-path half of GNO-CTX-008. A Turn caller submits an
/// episode and returns immediately; the coordinator curates on a separate task
/// so curator latency never adds Turn latency. Each `ContextStoreKey` partition
/// runs at most one curation at a time, keeps a bounded ordered queue, and is
/// independent of every other partition.
///
/// The coordinator never trusts a curator. It routes every proposal through the
/// host `ContextLeafCommitter`, which validates before it inserts. A curator
/// failure, a rejection, or a shutdown leaves the store and the conversation
/// untouched.
///
/// ``shutdown()`` is a fence: it refuses new work and waits for in-flight tasks
/// to drain. A curator result that arrives after the fence starts is discarded,
/// so no accepted write lands after ``shutdown()`` returns.
public actor ContextCurationCoordinator {
    /// The per-partition state.
    private struct Partition {
        var pending: [ContextEpisode] = []
        var inFlight: Task<Void, Never>?
        var diagnostics = ContextCurationDiagnostics()
    }

    /// The store the coordinator writes accepted nodes into.
    public let store: InMemoryContextStore
    /// The validator the committer uses.
    public let validator: ContextProposalValidator
    /// The host-owned bounds.
    public let descriptor: ContextDescriptor
    /// The maximum number of episodes held behind the in-flight curation.
    public let maxPendingPerTimeline: Int

    private let curator: any ContextCurator
    private let reducer = ContextCarryReducer()
    private let committer: ContextLeafCommitter
    private var partitions: [ContextStoreKey: Partition] = [:]
    private var isShuttingDown = false

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - store: The accepted-node store.
    ///   - validator: The host validator.
    ///   - curator: The untrusted curator. It has no store authority.
    ///   - descriptor: The host-owned bounds.
    ///   - maxPendingPerTimeline: The queue bound. A value below one is raised to
    ///     one.
    public init(
        store: InMemoryContextStore,
        validator: ContextProposalValidator,
        curator: any ContextCurator,
        descriptor: ContextDescriptor,
        maxPendingPerTimeline: Int = 4
    ) {
        self.store = store
        self.validator = validator
        self.curator = curator
        self.descriptor = descriptor
        self.maxPendingPerTimeline = max(1, maxPendingPerTimeline)
        self.committer = ContextLeafCommitter(store: store, validator: validator)
    }

    /// Queues one immutable episode for curation.
    ///
    /// The call returns as soon as the episode is queued. It never awaits the
    /// curator, so a Turn handler can call it on the response path.
    ///
    /// When the queue is full, the coordinator folds the episode into the newest
    /// queued episode and counts an overflow merge. The plan keeps every
    /// uncurated Turn; it never drops one.
    ///
    /// - Parameters:
    ///   - episode: The episode to curate.
    ///   - key: The Ascendant and Timeline partition.
    public func submit(_ episode: ContextEpisode, for key: ContextStoreKey) {
        guard episode.timelineID == key.timelineID else {
            var partition = partitions[key] ?? Partition()
            partition.diagnostics.rejected += 1
            partition.diagnostics.lastError = .crossTimeline
            partitions[key] = partition
            return
        }
        guard !isShuttingDown else {
            var partition = partitions[key] ?? Partition()
            partition.diagnostics.rejectedAfterShutdown += 1
            partitions[key] = partition
            return
        }
        var partition = partitions[key] ?? Partition()
        partition.diagnostics.submitted += 1
        if partition.pending.count >= maxPendingPerTimeline, let newest = partition.pending.popLast() {
            partition.pending.append(ContextEpisode(
                timelineID: newest.timelineID,
                messages: newest.messages + episode.messages
            ))
            partition.diagnostics.overflowMerges += 1
        } else {
            partition.pending.append(episode)
        }
        partitions[key] = partition
        ensureDraining(key)
    }

    /// Returns the current lifecycle state for one partition.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The state. After ``shutdown()`` starts, every partition
    ///   reports ``ContextCurationState/stopping``.
    public func state(for key: ContextStoreKey) -> ContextCurationState {
        if isShuttingDown { return .stopping }
        guard let partition = partitions[key], partition.inFlight != nil else { return .idle }
        return partition.pending.isEmpty ? .curating : .pending
    }

    /// Returns the payload-free diagnostics for one partition.
    ///
    /// - Parameter key: The partition.
    /// - Returns: The diagnostics.
    public func diagnostics(for key: ContextStoreKey) -> ContextCurationDiagnostics {
        partitions[key]?.diagnostics ?? ContextCurationDiagnostics()
    }

    /// Waits until the partition has no in-flight curation and no queued work.
    ///
    /// - Parameter key: The partition.
    public func waitUntilIdle(for key: ContextStoreKey) async {
        while let task = partitions[key]?.inFlight {
            await task.value
        }
    }

    /// Fences the coordinator: refuse new work and drain the in-flight tasks.
    ///
    /// A curator result that arrives after the fence starts is discarded, so no
    /// accepted write lands after this call returns. Diagnostics stay readable.
    public func shutdown() async {
        isShuttingDown = true
        let tasks = partitions.values.compactMap(\.inFlight)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func ensureDraining(_ key: ContextStoreKey) {
        guard !isShuttingDown else { return }
        guard partitions[key]?.inFlight == nil, partitions[key]?.pending.isEmpty == false else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drain(key)
        }
        partitions[key]?.inFlight = task
    }

    private func drain(_ key: ContextStoreKey) async {
        while !isShuttingDown {
            guard var partition = partitions[key], !partition.pending.isEmpty else { break }
            let episode = partition.pending.removeFirst()
            partition.diagnostics.started += 1
            partitions[key] = partition
            await curate(episode, for: key)
        }
        partitions[key]?.inFlight = nil
    }

    private func curate(_ episode: ContextEpisode, for key: ContextStoreKey) async {
        let nodes = await store.acceptedNodes(for: key)
        let activeCarry = reducer.reduce(nodes.map(\.carry))
        do {
            let proposal = try await curator.propose(
                episode: episode,
                activeCarry: activeCarry,
                descriptor: descriptor
            )
            guard !isShuttingDown else {
                partitions[key, default: Partition()].diagnostics.rejectedAfterShutdown += 1
                return
            }
            let leaf = ContextLeafProposal(
                episode: episode,
                proposal: proposal,
                curatorVersion: curator.version
            )
            _ = try await committer.commit(leaf, for: key, activeCarry: activeCarry)
            partitions[key, default: Partition()].diagnostics.accepted += 1
        } catch let error as ContextError {
            partitions[key, default: Partition()].diagnostics.rejected += 1
            partitions[key, default: Partition()].diagnostics.lastError = error
        } catch {
            partitions[key, default: Partition()].diagnostics.failures += 1
        }
    }
}
