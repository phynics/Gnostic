// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts

/// Structured failures raised by the Atlas store.
public enum AtlasStoreError: Error, Equatable, Sendable, PKError {
    /// A Shard or value belongs to a different Ascendant or backend binding.
    case identityMismatch
    /// A stable Shard identity was registered with conflicting binding data.
    case conflictingBinding
    /// A report or patch reused an identity with different content.
    case reportIdentityConflict
    /// A patch identity was reused with different content.
    case patchIdentityConflict
    /// The requested Shard is not registered.
    case unknownShard
    /// A detached or archived Shard cannot receive a new report.
    case inactiveShard
    /// An operation identifier is empty or otherwise invalid.
    case invalidOperationID
    /// A report sequence is not the next sequence for its Shard.
    case invalidSequence
    /// A CAS expected a different accepted state version.
    case staleState(expected: UInt64, actual: UInt64)
    /// A patch or capture refers to an unknown object.
    case invalidReference
    /// A patch claims a report absent from the report log.
    case claimedReportNotFound
    /// A watermark moves behind the accepted watermark.
    case watermarkRegression
    /// A capture does not match its patch or actor-owned report interval.
    case captureMismatch
    /// The Shard catalog changed after the capture was taken.
    case catalogChanged
    /// A replayed accepted history cannot produce valid state.
    case historyCorrupted

    public var errorDomain: String { "me.atkn.gnostic.positronic-atlas" }

    public var errorCode: Int {
        switch self {
        case .identityMismatch: 7001
        case .conflictingBinding: 7002
        case .reportIdentityConflict: 7003
        case .patchIdentityConflict: 7004
        case .unknownShard: 7005
        case .inactiveShard: 7006
        case .invalidOperationID: 7007
        case .invalidSequence: 7008
        case .staleState: 7009
        case .invalidReference: 7010
        case .claimedReportNotFound: 7011
        case .watermarkRegression: 7012
        case .captureMismatch: 7013
        case .catalogChanged: 7015
        case .historyCorrupted: 7014
        }
    }

    /// A stable machine-readable failure label.
    public var reasonCode: String {
        switch self {
        case .identityMismatch: "identityMismatch"
        case .conflictingBinding: "conflictingBinding"
        case .reportIdentityConflict: "reportIdentityConflict"
        case .patchIdentityConflict: "patchIdentityConflict"
        case .unknownShard: "unknownShard"
        case .inactiveShard: "inactiveShard"
        case .invalidOperationID: "invalidOperationID"
        case .invalidSequence: "invalidSequence"
        case .staleState: "staleState"
        case .invalidReference: "invalidReference"
        case .claimedReportNotFound: "claimedReportNotFound"
        case .watermarkRegression: "watermarkRegression"
        case .captureMismatch: "captureMismatch"
        case .catalogChanged: "catalogChanged"
        case .historyCorrupted: "historyCorrupted"
        }
    }

    /// The HTTP-like status used by adapters that need a coarse classification.
    public var statusCode: Int {
        switch self {
        case .staleState, .watermarkRegression, .conflictingBinding, .reportIdentityConflict, .patchIdentityConflict, .catalogChanged:
            409
        case .unknownShard, .claimedReportNotFound:
            404
        case .inactiveShard:
            423
        case .historyCorrupted:
            500
        default:
            400
        }
    }

    /// Whether retrying with a newly captured state may succeed.
    public var retryable: Bool {
        switch self {
        case .staleState, .watermarkRegression, .catalogChanged:
            true
        default:
            false
        }
    }

    /// A safe message for ErrorKit and user-facing adapters. Report, item, and
    /// source payloads are intentionally absent.
    public var userFriendlyMessage: String {
        switch self {
        case .identityMismatch: "The Atlas identity does not match the active Ascendant."
        case .conflictingBinding: "The Atlas Shard binding conflicts with the registered binding."
        case .reportIdentityConflict: "The Shard Report identity was reused with different data."
        case .patchIdentityConflict: "The Atlas patch identity was reused with different data."
        case .unknownShard: "The Atlas Shard was not found."
        case .inactiveShard: "The Atlas Shard is not active."
        case .invalidOperationID: "The Ascendant operation identity is invalid."
        case .invalidSequence: "The Shard Report sequence is invalid."
        case .staleState: "The Atlas state is stale; capture the current state and retry."
        case .invalidReference: "The Atlas patch contains an invalid reference."
        case .claimedReportNotFound: "A claimed Shard Report was not found."
        case .watermarkRegression: "The Atlas watermark cannot move backwards."
        case .captureMismatch: "The Atlas integration capture is no longer valid."
        case .catalogChanged: "The Atlas Shard catalog changed; capture the current state and retry."
        case .historyCorrupted: "The accepted Atlas history cannot be replayed."
        }
    }

    /// The safe public message spelling used by Gnostic adapters.
    public var publicMessage: String { userFriendlyMessage }
}

/// The actor-safe interface for one Ascendant's Atlas state and report log.
public protocol AtlasStore: Sendable {
    /// The immutable Ascendant identity owned by this store.
    var ascendantID: UUID { get async }

    /// Registers an immutable Shard binding.
    func register(_ shard: AscendantShard) async throws -> AtlasRegistrationResult

    /// Appends a report draft and assigns its next per-Shard sequence.
    func append(_ draft: ShardReportDraft) async throws -> AtlasAppendResult

    /// Appends an already sequenced report, for replay/import adapters.
    func append(_ report: AscendantShardReport) async throws -> AtlasAppendResult

    /// Returns the current immutable accepted state.
    func snapshot() async -> AscendantAtlas

    /// Returns the canonical registered Shard catalog.
    func registrations() async -> [AscendantShard]

    /// Returns all reports not yet consumed by an accepted watermark.
    func pendingReports() async -> [AscendantShardReport]

    /// Captures accepted state and one immutable causal report cut.
    func capture() async -> AtlasIntegrationCapture

    /// Atomically accepts a patch against its capture.
    func compareAndSwap(capture: AtlasIntegrationCapture, patch: AtlasPatch) async throws -> AtlasCommitReceipt

    /// Returns accepted patches after a resulting state version.
    func acceptedPatchHistory(after stateVersion: UInt64) async -> [AtlasAcceptedPatch]

    /// Replays accepted patches to the requested resulting state version.
    func replay(to stateVersion: UInt64?) async throws -> AscendantAtlas
}

/// An actor-backed, in-memory Atlas store for one Ascendant.
public actor InMemoryAtlasStore: AtlasStore {
    /// The immutable Ascendant identity owned by this store.
    public let ascendantID: UUID

    private let binding: AscendantAtlasBinding
    private var state: AscendantAtlas
    private var shards: [AscendantShardID: AscendantShard] = [:]
    private var reports: [AtlasReportID: AscendantShardReport] = [:]
    private var reportDrafts: [AtlasReportID: ShardReportDraft] = [:]
    private var reportHeads: [AscendantShardID: UInt64] = [:]
    private var history: [AtlasAcceptedPatch] = []
    private var receipts: [AtlasPatchID: AtlasCommitReceipt] = [:]

    /// Creates an empty store for one Ascendant.
    public init(ascendantID: UUID, bindingID: UUID = UUID()) {
        let binding = AscendantAtlasBinding(ascendantID: ascendantID, bindingID: bindingID)
        self.ascendantID = ascendantID
        self.binding = binding
        self.state = AscendantAtlas(ascendantID: ascendantID)
    }

    /// Creates an empty store from an explicit backend binding.
    public init(binding: AscendantAtlasBinding) {
        self.ascendantID = binding.ascendantID
        self.binding = binding
        self.state = AscendantAtlas(ascendantID: binding.ascendantID)
    }

    /// Registers an immutable Shard binding. Exact repeats are idempotent.
    public func register(_ shard: AscendantShard) throws -> AtlasRegistrationResult {
        guard shard.ascendantID == ascendantID else { throw AtlasStoreError.identityMismatch }
        if let shardBindingID = shard.bindingID, shardBindingID != binding.bindingID {
            throw AtlasStoreError.conflictingBinding
        }

        if let existing = shards[shard.id] {
            guard existing == shard else { throw AtlasStoreError.conflictingBinding }
            return AtlasRegistrationResult(shard: existing, wasInserted: false)
        }

        shards[shard.id] = shard
        reportHeads[shard.id] = 0
        return AtlasRegistrationResult(shard: shard, wasInserted: true)
    }

    /// Appends a draft and assigns the next contiguous sequence for its Shard.
    public func append(_ draft: ShardReportDraft) throws -> AtlasAppendResult {
        try validate(draft)
        let reportID = AtlasReportID(shardID: draft.shardID, operationID: draft.operationID)

        if let existing = reports[reportID] {
            guard reportDrafts[reportID] == draft else { throw AtlasStoreError.reportIdentityConflict }
            return AtlasAppendResult(report: existing, wasInserted: false)
        }

        let sequence = (reportHeads[draft.shardID] ?? 0) + 1
        let report = AscendantShardReport(draft: draft, sequence: sequence)
        reports[report.id] = report
        reportDrafts[report.id] = draft
        reportHeads[draft.shardID] = sequence
        return AtlasAppendResult(report: report, wasInserted: true)
    }

    /// Appends a pre-sequenced report for replay/import adapters.
    public func append(_ report: AscendantShardReport) throws -> AtlasAppendResult {
        try validate(report)
        if let existing = reports[report.id] {
            guard existing == report else { throw AtlasStoreError.reportIdentityConflict }
            return AtlasAppendResult(report: existing, wasInserted: false)
        }

        guard report.sequence == (reportHeads[report.shardID] ?? 0) + 1 else {
            throw AtlasStoreError.invalidSequence
        }
        reports[report.id] = report
        reportDrafts[report.id] = ShardReportDraft(
            ascendantID: report.ascendantID,
            shardID: report.shardID,
            operationID: report.operationID.rawValue,
            content: report.content,
            claims: report.claims,
            outcome: report.outcome,
            occurredAt: report.occurredAt,
            recordedAt: report.recordedAt,
            provenance: report.provenance
        )
        reportHeads[report.shardID] = report.sequence
        return AtlasAppendResult(report: report, wasInserted: true)
    }

    /// Returns the current accepted state as a canonical value copy.
    public func snapshot() -> AscendantAtlas { state }

    /// Returns the canonical registered Shard catalog.
    public func registrations() -> [AscendantShard] { canonicalShards() }

    /// Returns reports after the accepted watermark cut.
    public func pendingReports() -> [AscendantShardReport] {
        pendingReports(upTo: reportHeads)
    }

    /// Captures accepted state and all reports currently available after its
    /// consumed watermarks. Later appends are outside this value capture.
    public func capture() -> AtlasIntegrationCapture {
        let cut = reportHeads.map { AtlasWatermark(shardID: $0.key, sequence: $0.value) }.sorted()
        let pending = pendingReports(upTo: reportHeads)
        let catalog = canonicalShards()
        let captureID = AtlasCaptureID(
            rawValue: makeCaptureID(registrations: catalog, watermarks: cut, reports: pending)
        )
        return AtlasIntegrationCapture(
            id: captureID,
            state: state,
            registrations: catalog,
            watermarks: cut,
            pendingReports: pending
        )
    }

    /// Accepts a patch only when the complete capture still describes the
    /// actor-owned state and report interval.
    public func compareAndSwap(capture: AtlasIntegrationCapture, patch: AtlasPatch) throws -> AtlasCommitReceipt {
        if let existing = receipts[patch.id] {
            guard existing.acceptedPatch.patch == patch else { throw AtlasStoreError.patchIdentityConflict }
            return AtlasCommitReceipt(
                acceptedPatch: existing.acceptedPatch,
                state: existing.state,
                wasIdempotent: true
            )
        }

        guard patch.ascendantID == ascendantID, capture.ascendantID == ascendantID,
              patch.provenance.ascendantID == ascendantID else {
            throw AtlasStoreError.identityMismatch
        }
        guard capture.state == state, patch.baseStateVersion == state.stateVersion else {
            throw AtlasStoreError.staleState(expected: patch.baseStateVersion, actual: state.stateVersion)
        }
        guard capture.registrations == canonicalShards() else { throw AtlasStoreError.catalogChanged }
        guard patch.captureID == capture.id else { throw AtlasStoreError.captureMismatch }

        let expectedPending = pendingReports(upTo: capture.watermarks)
        guard capture.pendingReports == expectedPending else { throw AtlasStoreError.captureMismatch }
        for reportID in patch.claimedReportIDs {
            guard let report = reports[reportID] else {
                throw AtlasStoreError.claimedReportNotFound
            }
            guard capture.pendingReports.contains(report) else { throw AtlasStoreError.claimedReportNotFound }
        }
        guard patch.watermarks == capture.watermarks,
              patch.claimedReportIDs == capture.pendingReports.map(\.id).sorted() else {
            throw AtlasStoreError.captureMismatch
        }

        try validateWatermarks(patch.watermarks)

        let nextState = try apply(patch, to: state)
        let accepted = AtlasAcceptedPatch(
            patch: patch,
            baseVersion: state.version,
            resultingVersion: nextState.version,
            consumedWatermarks: nextState.watermarks
        )
        let receipt = AtlasCommitReceipt(acceptedPatch: accepted, state: nextState)
        state = nextState
        history.append(accepted)
        receipts[patch.id] = receipt
        return receipt
    }

    /// Commits a patch against a freshly captured state version.
    public func commit(_ patch: AtlasPatch, expectedStateVersion: UInt64) throws -> AtlasCommitReceipt {
        let capture = capture()
        guard capture.baseStateVersion == expectedStateVersion else {
            throw AtlasStoreError.staleState(expected: expectedStateVersion, actual: capture.baseStateVersion)
        }
        return try compareAndSwap(capture: capture, patch: patch)
    }

    /// Returns accepted history in resulting state-version order.
    public func acceptedPatchHistory(after stateVersion: UInt64) -> [AtlasAcceptedPatch] {
        history.filter { $0.stateVersion > stateVersion }
    }

    /// Replays the accepted history without mutating the actor state.
    public func replay(to stateVersion: UInt64?) throws -> AscendantAtlas {
        let target = stateVersion ?? state.stateVersion
        guard target <= state.stateVersion else { throw AtlasStoreError.historyCorrupted }

        var replayed = AscendantAtlas(ascendantID: ascendantID)
        for accepted in history where accepted.stateVersion <= target {
            guard accepted.baseVersion.stateVersion == replayed.stateVersion else {
                throw AtlasStoreError.historyCorrupted
            }
            replayed = try apply(accepted.patch, to: replayed)
            guard replayed.version == accepted.resultingVersion else {
                throw AtlasStoreError.historyCorrupted
            }
        }
        return replayed
    }

    private func validate(_ draft: ShardReportDraft) throws {
        guard draft.ascendantID == ascendantID,
              draft.provenance.ascendantID == ascendantID,
              draft.provenance.shardID == draft.shardID else {
            throw AtlasStoreError.identityMismatch
        }
        guard !draft.operationID.rawValue.isEmpty else { throw AtlasStoreError.invalidOperationID }
        guard let shard = shards[draft.shardID] else { throw AtlasStoreError.unknownShard }
        guard shard.lifecycle == .active else { throw AtlasStoreError.inactiveShard }
        if let operationID = draft.provenance.operationID, operationID != draft.operationID {
            throw AtlasStoreError.identityMismatch
        }
    }

    private func validate(_ report: AscendantShardReport) throws {
        guard report.ascendantID == ascendantID,
              report.provenance.ascendantID == ascendantID,
              report.provenance.shardID == report.shardID else {
            throw AtlasStoreError.identityMismatch
        }
        guard report.id == AtlasReportID(shardID: report.shardID, operationID: report.operationID) else {
            throw AtlasStoreError.identityMismatch
        }
        if let operationID = report.provenance.operationID, operationID != report.operationID {
            throw AtlasStoreError.identityMismatch
        }
        guard !report.operationID.rawValue.isEmpty, report.sequence > 0 else {
            throw AtlasStoreError.invalidSequence
        }
        guard let shard = shards[report.shardID] else { throw AtlasStoreError.unknownShard }
        guard shard.lifecycle == .active else { throw AtlasStoreError.inactiveShard }
    }

    private func validateWatermarks(_ values: [AtlasWatermark]) throws {
        var seen: Set<AscendantShardID> = []
        for watermark in values {
            guard seen.insert(watermark.shardID).inserted,
                  shards[watermark.shardID] != nil else { throw AtlasStoreError.invalidReference }
            let consumed = state.watermark(for: watermark.shardID)
            guard watermark.sequence >= consumed else { throw AtlasStoreError.watermarkRegression }
            guard watermark.sequence <= (reportHeads[watermark.shardID] ?? 0) else {
                throw AtlasStoreError.captureMismatch
            }
        }
    }

    private func pendingReports(upTo cut: [AscendantShardID: UInt64]) -> [AscendantShardReport] {
        reports.values.filter { report in
            report.sequence > state.watermark(for: report.shardID)
                && report.sequence <= (cut[report.shardID] ?? 0)
        }.sorted {
            ($0.shardID, $0.sequence, $0.id) < ($1.shardID, $1.sequence, $1.id)
        }
    }

    private func pendingReports(upTo cut: [AtlasWatermark]) -> [AscendantShardReport] {
        var bounds: [AscendantShardID: UInt64] = [:]
        for watermark in cut {
            bounds[watermark.shardID] = max(bounds[watermark.shardID] ?? 0, watermark.sequence)
        }
        return pendingReports(upTo: bounds)
    }

    private func makeCaptureID(
        registrations: [AscendantShard],
        watermarks: [AtlasWatermark],
        reports: [AscendantShardReport]
    ) -> String {
        let registrationPart = registrations.map { $0.id.rawValue.uuidString.lowercased() }.joined(separator: ",")
        let watermarkPart = watermarks.map { "\($0.shardID.rawValue.uuidString.lowercased())=\($0.sequence)" }.joined(separator: ",")
        let reportPart = reports.map(\.id.rawValue).joined(separator: ",")
        return "\(ascendantID.uuidString.lowercased())/\(state.stateVersion)/\(registrationPart)/\(watermarkPart)/\(reportPart)"
    }

    private func canonicalShards() -> [AscendantShard] {
        shards.values.sorted { $0.id < $1.id }
    }

    private func apply(_ patch: AtlasPatch, to current: AscendantAtlas) throws -> AscendantAtlas {
        guard patch.ascendantID == ascendantID,
              patch.provenance.ascendantID == ascendantID else { throw AtlasStoreError.identityMismatch }
        try validateWatermarksAgainstCurrent(patch.watermarks, current: current)

        var items = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
        var conflicts = Dictionary(uniqueKeysWithValues: current.conflicts.map { ($0.id, $0) })
        var directives = Dictionary(uniqueKeysWithValues: current.directives.map { ($0.id, $0) })

        for operation in patch.operations {
            switch operation {
            case let .upsertItem(item):
                try validate(item: item, shards: shards)
                items[item.id] = item
            case let .archiveItem(id):
                guard let item = items[id] else { throw AtlasStoreError.invalidReference }
                items[id] = AtlasItem(
                    id: item.id,
                    ascendantID: item.ascendantID,
                    sourceShardID: item.sourceShardID,
                    key: item.key,
                    value: item.value,
                    kind: item.kind,
                    applicability: item.applicability,
                    disclosure: item.disclosure,
                    epistemicStatus: item.epistemicStatus,
                    lifecycle: .archived,
                    provenance: item.provenance
                )
            case let .upsertConflict(conflict):
                try validate(conflict: conflict, items: items, shards: shards)
                conflicts[conflict.id] = conflict
            case let .resolveConflict(id):
                guard let conflict = conflicts[id] else { throw AtlasStoreError.invalidReference }
                conflicts[id] = AtlasConflict(
                    id: conflict.id,
                    ascendantID: conflict.ascendantID,
                    shardID: conflict.shardID,
                    itemIDs: conflict.itemIDs,
                    summary: conflict.summary,
                    applicability: conflict.applicability,
                    disclosure: conflict.disclosure,
                    isResolved: true,
                    provenance: conflict.provenance
                )
            case let .upsertDirective(directive):
                try validate(directive: directive, shards: shards)
                directives[directive.id] = directive
            case let .revokeDirective(id):
                guard let directive = directives[id] else { throw AtlasStoreError.invalidReference }
                directives[id] = AtlasDirective(
                    id: directive.id,
                    ascendantID: directive.ascendantID,
                    shardID: directive.shardID,
                    key: directive.key,
                    value: directive.value,
                    applicability: directive.applicability,
                    disclosure: directive.disclosure,
                    expiresAt: directive.expiresAt,
                    isRevoked: true,
                    provenance: directive.provenance
                )
            case .noOp:
                break
            }
        }

        let nextSemanticRevision = current.semanticRevision + (patch.isSemantic ? 1 : 0)
        let nextWatermarks = mergeWatermarks(current.watermarks, patch.watermarks)
        return AscendantAtlas(
            ascendantID: ascendantID,
            schemaVersion: current.schemaVersion,
            stateVersion: current.stateVersion + 1,
            semanticRevision: nextSemanticRevision,
            items: Array(items.values),
            conflicts: Array(conflicts.values),
            directives: Array(directives.values),
            watermarks: nextWatermarks
        )
    }

    private func validateWatermarksAgainstCurrent(_ values: [AtlasWatermark], current: AscendantAtlas) throws {
        var seen: Set<AscendantShardID> = []
        for watermark in values {
            guard seen.insert(watermark.shardID).inserted,
                  shards[watermark.shardID] != nil,
                  watermark.sequence >= current.watermark(for: watermark.shardID),
                  watermark.sequence <= (reportHeads[watermark.shardID] ?? 0) else {
                throw AtlasStoreError.watermarkRegression
            }
        }
    }

    private func validate(item: AtlasItem, shards: [AscendantShardID: AscendantShard]) throws {
        guard item.ascendantID == ascendantID,
              item.provenance.ascendantID == ascendantID,
              item.provenance.shardID == item.sourceShardID,
              shards[item.sourceShardID] != nil else { throw AtlasStoreError.invalidReference }
        try validate(applicability: item.applicability, disclosure: item.disclosure, shards: shards)
    }

    private func validate(conflict: AtlasConflict, items: [AtlasItemID: AtlasItem], shards: [AscendantShardID: AscendantShard]) throws {
        guard conflict.ascendantID == ascendantID,
              conflict.provenance.ascendantID == ascendantID,
              conflict.provenance.shardID == conflict.shardID,
              shards[conflict.shardID] != nil,
              conflict.itemIDs.allSatisfy({ items[$0] != nil }) else { throw AtlasStoreError.invalidReference }
        try validate(applicability: conflict.applicability, disclosure: conflict.disclosure, shards: shards)
    }

    private func validate(directive: AtlasDirective, shards: [AscendantShardID: AscendantShard]) throws {
        guard directive.ascendantID == ascendantID,
              directive.provenance.ascendantID == ascendantID else { throw AtlasStoreError.invalidReference }
        if let shardID = directive.shardID, shards[shardID] == nil {
            throw AtlasStoreError.invalidReference
        }
        try validate(applicability: directive.applicability, disclosure: directive.disclosure, shards: shards)
    }

    private func validate(
        applicability: AtlasApplicability,
        disclosure: AtlasDisclosure,
        shards: [AscendantShardID: AscendantShard]
    ) throws {
        let references: ([AscendantShardID]) -> Bool = { ids in ids.allSatisfy { shards[$0] != nil } }
        switch applicability {
        case let .shards(ids) where !references(ids): throw AtlasStoreError.invalidReference
        default: break
        }
        switch disclosure {
        case let .shards(ids) where !references(ids): throw AtlasStoreError.invalidReference
        default: break
        }
    }

    private func mergeWatermarks(_ current: [AtlasWatermark], _ incoming: [AtlasWatermark]) -> [AtlasWatermark] {
        let merged = Dictionary(current.map { ($0.shardID, $0) }, uniquingKeysWith: { _, newest in newest })
        let values = incoming.reduce(into: merged) { result, watermark in
            if watermark.sequence >= (result[watermark.shardID]?.sequence ?? 0) {
                result[watermark.shardID] = watermark
            }
        }
        return values.values.sorted()
    }
}

/// Explicit Ascendant spelling for the in-memory implementation.
public typealias InMemoryAscendantAtlasStore = InMemoryAtlasStore

/// The default store spelling used by Ascendant integrations.
public typealias AscendantAtlasStore = InMemoryAtlasStore

/// Convenience spellings shared by every Atlas store so the default call
/// surface is identical for concrete and existential callers.
public extension AtlasStore {
    /// Returns the complete accepted history.
    func acceptedPatchHistory() async -> [AtlasAcceptedPatch] {
        await acceptedPatchHistory(after: 0)
    }

    /// Replays the complete accepted history.
    func replay() async throws -> AscendantAtlas {
        try await replay(to: nil)
    }
}
