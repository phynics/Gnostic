// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PositronicKit

/// The immutable correlation identity of one admitted Ascendant Turn.
///
/// The Turn identity is the canonical Gnostic client Turn identity from the
/// reset. The coordinator already canonicalizes and validates it before the
/// Positronic backend runs, so Atlas consumes that identity to correlate the
/// projected snapshot instead of creating a second admission ledger. The
/// persisted report uses the admitted operation identity the coordinator mints
/// for every Turn (see ``AtlasShardReportRecorder``), which stays unique across
/// Timelines that reuse a client Turn id.
public struct AtlasTurnKey: Hashable, Sendable {
    /// The Gnostic Ascendant that owns the Turn.
    public let ascendantID: UUID
    /// The Gnostic Timeline the Turn ran on.
    public let timelineID: UUID
    /// The canonical Gnostic Turn identity.
    public let turnID: AtlasOperationID

    /// Creates a correlation identity from a typed Turn identity.
    public init(ascendantID: UUID, timelineID: UUID, turnID: AtlasOperationID) {
        self.ascendantID = ascendantID
        self.timelineID = timelineID
        self.turnID = turnID
    }

    /// Creates a correlation identity from a string Turn identity.
    public init(ascendantID: UUID, timelineID: UUID, turnID: String) {
        self.init(
            ascendantID: ascendantID,
            timelineID: timelineID,
            turnID: AtlasOperationID(turnID)
        )
    }
}

/// One immutable invocation context for an Ascendant Turn.
///
/// The context pins the Ascendant and Shard identity, the Gnostic Turn
/// identity, the activity origin, and the exact accepted Atlas snapshot
/// projected into Positronic prompt assembly. The same value is consumed at the
/// terminal Turn boundary, so a recorded report describes the revision actually
/// projected rather than a later live revision.
public struct AtlasTurnInvocation: Equatable, Sendable {
    /// The Gnostic Ascendant that owns the Turn.
    public let ascendantID: UUID
    /// The Gnostic Timeline the Turn ran on.
    public let timelineID: UUID
    /// The canonical Gnostic Turn identity.
    public let turnID: AtlasOperationID
    /// The Atlas Shard this Turn reports through.
    public let shardID: AscendantShardID
    /// The origin of the Turn's activity.
    public let origin: AtlasOrigin
    /// The exact accepted Atlas snapshot projected for the Turn.
    public let snapshot: AtlasSnapshot

    /// Creates an immutable invocation context.
    public init(
        ascendantID: UUID,
        timelineID: UUID,
        turnID: AtlasOperationID,
        shardID: AscendantShardID,
        origin: AtlasOrigin,
        snapshot: AtlasSnapshot
    ) {
        self.ascendantID = ascendantID
        self.timelineID = timelineID
        self.turnID = turnID
        self.shardID = shardID
        self.origin = origin
        self.snapshot = snapshot
    }

    /// The correlation identity of this invocation.
    public var key: AtlasTurnKey {
        AtlasTurnKey(
            ascendantID: ascendantID,
            timelineID: timelineID,
            turnID: turnID
        )
    }
}

/// The pending, first-capture-wins registry of Atlas Turn invocations.
///
/// The registry holds one immutable invocation per Turn between prompt
/// projection and the terminal boundary. A repeated registration returns the
/// first invocation, so a later projection cannot silently swap the snapshot
/// the prompt and the report are correlated against. Consumption is atomic and
/// one-shot so a duplicate terminal delivery cannot append twice.
public actor AtlasTurnCorrelator {
    private var pending: [AtlasTurnKey: AtlasTurnInvocation] = [:]

    /// Creates an empty correlator.
    public init() {}

    /// Registers an invocation, or returns the one already registered.
    ///
    /// - Parameter invocation: The proposed immutable invocation context.
    /// - Returns: The first invocation registered for the Turn.
    @discardableResult
    public func register(_ invocation: AtlasTurnInvocation) -> AtlasTurnInvocation {
        if let existing = pending[invocation.key] { return existing }
        pending[invocation.key] = invocation
        return invocation
    }

    /// Consumes the invocation for a Turn, at most once.
    ///
    /// - Parameter key: The Turn correlation identity.
    /// - Returns: The pending invocation, or `nil` when none is registered.
    public func consume(_ key: AtlasTurnKey) -> AtlasTurnInvocation? {
        pending.removeValue(forKey: key)
    }

    /// The number of pending invocations, for diagnostics and tests.
    public var pendingCount: Int { pending.count }
}

/// Projects a bounded Atlas context for one Positronic Turn and registers the
/// immutable invocation used to record that Turn's Shard Report.
///
/// The source reads the Gnostic Turn identity from
/// ``PositronicTurnInvocationContext/current`` directly. Atlas never aborts a
/// Turn: a missing identity, an unresolvable client Turn id, or an absent
/// snapshot produces no contribution and no report.
public struct AtlasTurnContextSource: TurnContextSource {
    /// The default contribution namespace.
    public static let defaultNamespace = "atlas"
    /// The default contribution key.
    public static let defaultKey = "context"
    /// The maximum projected context text in bytes.
    public static let maximumProjectionBytes = 512

    private let store: any AtlasStore
    private let correlator: AtlasTurnCorrelator
    private let shardID: AscendantShardID
    private let origin: AtlasOrigin
    private let namespace: String
    private let key: String

    /// Creates a context source for one Ascendant Shard.
    public init(
        store: any AtlasStore,
        correlator: AtlasTurnCorrelator,
        shardID: AscendantShardID,
        origin: AtlasOrigin = .ascendantTurn,
        namespace: String = AtlasTurnContextSource.defaultNamespace,
        key: String = AtlasTurnContextSource.defaultKey
    ) {
        self.store = store
        self.correlator = correlator
        self.shardID = shardID
        self.origin = origin
        self.namespace = namespace
        self.key = key
    }

    /// Atlas context is additive: a missing projection never fails a Turn.
    public var failureRequirement: TurnContextContributionRequirement { .optional }

    /// Projects the bounded Atlas context and registers the invocation.
    ///
    /// - Returns: One bounded contribution, or an empty array when the Turn has
    ///   no correlatable Gnostic identity.
    /// - Throws: ``TurnContextContributionError`` when the projection does not
    ///   satisfy the PositronicKit contribution bounds.
    public func contributions(for _: TurnContextRequest) async throws -> [TurnContextContribution] {
        guard let invocation = PositronicTurnInvocationContext.current,
              let rawTurnID = invocation.turnID,
              let turnIDString = try? GnosticWirePayload.canonicalClientTurnID(rawTurnID) else {
            return []
        }
        let turnID = AtlasOperationID(turnIDString)
        guard !turnID.rawValue.isEmpty else { return [] }

        let proposed = AtlasTurnInvocation(
            ascendantID: invocation.ascendantID,
            timelineID: invocation.timelineID,
            turnID: turnID,
            shardID: shardID,
            origin: origin,
            snapshot: await store.snapshot()
        )
        let registered = await correlator.register(proposed)
        return [try TurnContextContribution(
            namespace: namespace,
            key: key,
            text: Self.projection(for: registered),
            requirement: .optional
        )]
    }

    /// A bounded, deterministic description of the projected revision.
    ///
    /// #118 replaces this summary with the scoped Ascendant Brief; #116 only
    /// needs the projection to pin the exact snapshot the report is tied to.
    static func projection(for invocation: AtlasTurnInvocation) -> String {
        let version = invocation.snapshot.version
        let text = "Atlas revision \(version.semanticRevision) at state \(version.stateVersion); "
            + "\(invocation.snapshot.items.count) accepted item(s)."
        return GnosticWirePayload.prefix(text, maximumBytes: maximumProjectionBytes)
    }
}

/// Records exactly one Shard Report for each original terminal Ascendant Turn
/// through the generic ``TerminalTurnObserving`` seam.
///
/// The recorder correlates the terminal record to the invocation projected for
/// the same Turn, suppresses Atlas-origin activity, and appends one
/// deterministic report. The coordinator only invokes the seam for an original
/// terminal commit, so replays, conflicts, and tombstones never append.
///
/// The persisted operation identity is the coordinator's admitted
/// `TerminalTurnRecord.operationID`, which is unique for every admitted Turn,
/// including Turns with no client Turn id and Turns on different Timelines that
/// reuse the same client Turn id. When no projected invocation is available,
/// the report is still recorded without a projected revision.
///
/// One recorder belongs to one Ascendant Shard and one activity origin. Do not
/// route Atlas-origin work through an integration configured for
/// ``AtlasOrigin/ascendantTurn``; that would tag it as ordinary work. A fence
/// that stops observation (ADR 0006 shutdown) can leave a pending invocation
/// unconsumed; the correlator retains it until the serve lifetime ends, and a
/// durable outbox is future work.
public struct AtlasShardReportRecorder: TerminalTurnObserving {
    /// The maximum report content in bytes.
    public static let maximumContentBytes = 512

    private let store: any AtlasStore
    private let correlator: AtlasTurnCorrelator
    private let shardID: AscendantShardID
    private let origin: AtlasOrigin

    /// Creates a recorder over the shared store and correlator.
    public init(
        store: any AtlasStore,
        correlator: AtlasTurnCorrelator,
        shardID: AscendantShardID,
        origin: AtlasOrigin = .ascendantTurn
    ) {
        self.store = store
        self.correlator = correlator
        self.shardID = shardID
        self.origin = origin
    }

    /// Consumes the pending invocation and appends one deterministic report.
    ///
    /// - Parameter record: The generic terminal Turn record.
    public func observe(_ record: TerminalTurnRecord) async throws {
        let invocation: AtlasTurnInvocation?
        if let clientTurnID = record.clientTurnID {
            invocation = await correlator.consume(AtlasTurnKey(
                ascendantID: record.ascendantID,
                timelineID: record.timelineID,
                turnID: clientTurnID
            ))
        } else {
            invocation = nil
        }
        let recordedShardID = invocation?.shardID ?? shardID
        let recordedOrigin = invocation?.origin ?? origin
        // Atlas-origin integration activity is never recaptured as ordinary work.
        guard recordedOrigin == .ascendantTurn else { return }
        _ = try await store.append(Self.draft(
            for: record,
            shardID: recordedShardID,
            origin: recordedOrigin,
            projectedVersion: invocation?.snapshot.version
        ))
    }

    /// Builds the deterministic report draft for one terminal record.
    static func draft(
        for record: TerminalTurnRecord,
        shardID: AscendantShardID,
        origin: AtlasOrigin,
        projectedVersion: AtlasVersion?
    ) -> ShardReportDraft {
        let operationID = record.operationID
        return ShardReportDraft(
            ascendantID: record.ascendantID,
            shardID: shardID,
            operationID: operationID,
            content: content(for: record.outcome, operationID: operationID),
            claims: [],
            outcome: reportOutcome(for: record.outcome),
            provenance: AtlasProvenance(
                ascendantID: record.ascendantID,
                shardID: shardID,
                operationID: operationID,
                origin: origin,
                timelineID: record.timelineID
            ),
            projectedVersion: projectedVersion
        )
    }

    /// Maps a generic terminal outcome to its bounded report outcome.
    static func reportOutcome(for outcome: TerminalTurnOutcome) -> ShardReportOutcome {
        switch outcome {
        case .succeeded: .succeeded
        case .cancelled: .cancelled
        case let .failed(failure): .failed(reasonCode: failure.reasonCode)
        }
    }

    /// A bounded, deterministic summary for one terminal outcome.
    static func content(for outcome: TerminalTurnOutcome, operationID: String) -> String {
        let summary: String
        switch outcome {
        case .succeeded: summary = "succeeded"
        case .cancelled: summary = "was cancelled"
        case let .failed(failure): summary = "failed (\(failure.reasonCode))"
        }
        return GnosticWirePayload.prefix(
            "Ascendant Turn \(operationID) \(summary).",
            maximumBytes: maximumContentBytes
        )
    }
}

/// Composes the Atlas Turn contribution and the Shard Report recorder for one
/// Ascendant Shard.
///
/// A composition root installs ``contribution`` in the Positronic backend and
/// ``observer`` in the generic terminal Turn observer list.
public struct AtlasTurnIntegration: Sendable {
    /// The Positronic contribution that installs the Turn context source.
    public let contribution: AtlasTurnContribution
    /// The generic terminal Turn observer that records Shard Reports.
    public let observer: AtlasShardReportRecorder

    /// Creates one correlated contribution/observer pair.
    public init(
        store: any AtlasStore,
        shardID: AscendantShardID,
        origin: AtlasOrigin = .ascendantTurn,
        namespace: String = AtlasTurnContextSource.defaultNamespace,
        key: String = AtlasTurnContextSource.defaultKey
    ) {
        let correlator = AtlasTurnCorrelator()
        let source = AtlasTurnContextSource(
            store: store,
            correlator: correlator,
            shardID: shardID,
            origin: origin,
            namespace: namespace,
            key: key
        )
        self.contribution = AtlasTurnContribution(source: source)
        self.observer = AtlasShardReportRecorder(
            store: store,
            correlator: correlator,
            shardID: shardID,
            origin: origin
        )
    }
}

/// The static Positronic contribution that installs the Atlas Turn context.
public struct AtlasTurnContribution: PositronicContribution {
    /// The static contribution label used in diagnostics.
    public static let defaultLabel = "atlas.turn"

    /// The static contribution label.
    public let label: String
    private let source: any TurnContextSource

    /// Creates a contribution over one Turn context source.
    public init(
        label: String = AtlasTurnContribution.defaultLabel,
        source: any TurnContextSource
    ) {
        self.label = label
        self.source = source
    }

    /// The Atlas Turn context source.
    ///
    /// - Returns: The installed source.
    public func turnContextSource() -> (any TurnContextSource)? { source }
}
