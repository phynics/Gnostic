// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The host-normalized, validated result of one integrator proposal.
public struct AtlasValidatedIntegration: Equatable, Sendable {
    /// The host-built patch. Its identity, capture metadata, watermarks, and
    /// claimed reports are host-owned.
    public let patch: AtlasPatch
    /// Whether the patch changes prompt-visible semantic state.
    public let isSemantic: Bool
    /// The number of captured reports the patch consumes exactly.
    public let consumedReportCount: Int

    /// Creates a validated integration.
    public init(patch: AtlasPatch, isSemantic: Bool, consumedReportCount: Int) {
        self.patch = patch
        self.isSemantic = isSemantic
        self.consumedReportCount = consumedReportCount
    }
}

/// Deterministic host validation for one untrusted integrator proposal.
///
/// The validator is a pure function over `(descriptor, capture, proposal)`. It
/// re-derives durable identity, re-stamps provenance, and rejects anything that
/// would claim host-only authority, broaden disclosure, break lifecycle
/// monotonicity, reference unknown state, exceed a budget, or consume the
/// captured cut inexactly. A proposal that passes yields a host-built
/// ``AtlasPatch`` that the store can compare-and-swap.
public struct AtlasHostValidator: Sendable {
    /// The maximum accepted semantic key length in bytes.
    public static let maximumKeyBytes = 256

    /// Creates a host validator.
    public init() {}

    /// Validates and normalizes one proposal against one capture.
    ///
    /// - Throws: ``AtlasIntegrationError`` for any rejected proposal. The
    ///   accepted state is never touched by validation.
    public func validate(
        descriptor: AtlasIntegratorDescriptor,
        capture: AtlasIntegrationCapture,
        proposal: AtlasIntegrationProposal
    ) throws -> AtlasValidatedIntegration {
        try validate(descriptor: descriptor)
        try validate(capture: capture, maximumInputReports: descriptor.maximumInputReports)
        try validate(budgets: descriptor, proposal: proposal)

        let ascendantID = capture.ascendantID
        let shards = Dictionary(capture.registrations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pendingByOperation = Dictionary(
            capture.pendingReports.map { ($0.operationID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var items = Dictionary(capture.state.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var conflicts = Dictionary(capture.state.conflicts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var directives = Dictionary(capture.state.directives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var operations: [AtlasPatchOperation] = []
        var upsertedItems: Set<AtlasItemID> = []
        var upsertedConflicts: Set<AtlasConflictID> = []
        var upsertedDirectives: Set<AtlasDirectiveID> = []

        for operation in proposal.operations {
            switch operation {
            case .noOp:
                continue

            case let .upsertItem(item):
                let normalized = try normalize(
                    item: item,
                    ascendantID: ascendantID,
                    shards: shards,
                    pendingByOperation: pendingByOperation,
                    existing: items
                )
                guard upsertedItems.insert(normalized.id).inserted else { throw AtlasIntegrationError.duplicateOperation }
                items[normalized.id] = normalized
                operations.append(.upsertItem(normalized))

            case let .archiveItem(id):
                guard let existing = items[id] else { throw AtlasIntegrationError.invalidReference }
                guard existing.lifecycle != .retracted else { throw AtlasIntegrationError.invalidLifecycle }
                items[id] = archived(existing)
                operations.append(.archiveItem(id))

            case let .upsertConflict(conflict):
                let normalized = try normalize(
                    conflict: conflict,
                    ascendantID: ascendantID,
                    shards: shards,
                    pendingByOperation: pendingByOperation,
                    items: items,
                    maximumProseBytes: descriptor.maximumProseBytes
                )
                guard upsertedConflicts.insert(normalized.id).inserted else { throw AtlasIntegrationError.duplicateOperation }
                if let existing = conflicts[normalized.id], existing.isResolved, !normalized.isResolved {
                    throw AtlasIntegrationError.invalidConflict
                }
                conflicts[normalized.id] = normalized
                operations.append(.upsertConflict(normalized))

            case let .resolveConflict(id):
                guard let existing = conflicts[id] else { throw AtlasIntegrationError.invalidReference }
                conflicts[id] = resolved(existing)
                operations.append(.resolveConflict(id))

            case let .upsertDirective(directive):
                let normalized = try normalize(
                    directive: directive,
                    ascendantID: ascendantID,
                    shards: shards,
                    pendingByOperation: pendingByOperation
                )
                guard upsertedDirectives.insert(normalized.id).inserted else { throw AtlasIntegrationError.duplicateOperation }
                if let existing = directives[normalized.id] {
                    if existing.isRevoked, !normalized.isRevoked { throw AtlasIntegrationError.invalidDirective }
                } else if normalized.isRevoked {
                    throw AtlasIntegrationError.invalidDirective
                }
                directives[normalized.id] = normalized
                operations.append(.upsertDirective(normalized))

            case let .revokeDirective(id):
                guard let existing = directives[id] else { throw AtlasIntegrationError.invalidReference }
                directives[id] = revoked(existing)
                operations.append(.revokeDirective(id))
            }
        }

        let normalizedOperations = operations.isEmpty ? [AtlasPatchOperation.noOp] : operations
        let isSemantic = normalizedOperations.contains(where: \.isSemantic)
        guard let provenanceShardID = capture.pendingReports.first?.shardID ?? capture.registrations.first?.id else {
            throw AtlasIntegrationError.invalidReference
        }

        let patch = AtlasPatch(
            id: AtlasHostIdentity.patchID(ascendantID: ascendantID, captureID: capture.id),
            ascendantID: ascendantID,
            baseStateVersion: capture.baseStateVersion,
            captureID: capture.id,
            claimedReportIDs: capture.pendingReports.map(\.id),
            watermarks: capture.watermarks,
            operations: normalizedOperations,
            provenance: AtlasProvenance(ascendantID: ascendantID, shardID: provenanceShardID, origin: .host)
        )
        try validate(consumption: capture, patch: patch)

        return AtlasValidatedIntegration(
            patch: patch,
            isSemantic: isSemantic,
            consumedReportCount: capture.pendingReports.count
        )
    }

    // MARK: - Versions and capture

    private func validate(descriptor: AtlasIntegratorDescriptor) throws {
        let identifier = descriptor.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = descriptor.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !version.isEmpty,
              descriptor.maximumInputReports >= 0,
              descriptor.maximumOperations >= 0,
              descriptor.maximumProseBytes >= 0 else {
            throw AtlasIntegrationError.invalidIntegratorDescriptor
        }
        guard descriptor.schemaVersion == AtlasIntegratorDescriptor.currentSchemaVersion else {
            throw AtlasIntegrationError.unsupportedIntegratorSchema(
                expected: AtlasIntegratorDescriptor.currentSchemaVersion,
                actual: descriptor.schemaVersion
            )
        }
    }

    private func validate(capture: AtlasIntegrationCapture, maximumInputReports: Int) throws {
        guard capture.state.ascendantID == capture.ascendantID else { throw AtlasIntegrationError.identityMismatch }
        guard capture.state.schemaVersion == AscendantAtlas.currentSchemaVersion else {
            throw AtlasIntegrationError.unsupportedStateSchema(
                expected: AscendantAtlas.currentSchemaVersion,
                actual: capture.state.schemaVersion
            )
        }

        let registrationIDs = capture.registrations.map(\.id)
        guard registrationIDs == registrationIDs.sorted(),
              Set(registrationIDs).count == registrationIDs.count else {
            throw AtlasIntegrationError.captureMismatch
        }

        let watermarkIDs = capture.watermarks.map(\.shardID)
        guard watermarkIDs == watermarkIDs.sorted(),
              Set(watermarkIDs).count == watermarkIDs.count else {
            throw AtlasIntegrationError.captureMismatch
        }
        for watermark in capture.watermarks {
            guard registrationIDs.contains(watermark.shardID) else { throw AtlasIntegrationError.invalidReference }
            guard watermark.sequence >= capture.state.watermark(for: watermark.shardID) else {
                throw AtlasIntegrationError.watermarkMismatch
            }
        }

        var reportIDs: Set<AtlasReportID> = []
        for report in capture.pendingReports {
            guard report.ascendantID == capture.ascendantID else { throw AtlasIntegrationError.identityMismatch }
            guard reportIDs.insert(report.id).inserted else { throw AtlasIntegrationError.captureMismatch }
            guard registrationIDs.contains(report.shardID) else { throw AtlasIntegrationError.invalidReference }
            guard report.sequence > capture.state.watermark(for: report.shardID) else {
                throw AtlasIntegrationError.watermarkMismatch
            }
            guard let cut = capture.watermarks.first(where: { $0.shardID == report.shardID }),
                  report.sequence <= cut.sequence else {
                throw AtlasIntegrationError.watermarkMismatch
            }
        }

        guard capture.pendingReports.count <= maximumInputReports else {
            throw AtlasIntegrationError.budgetExceeded
        }
    }

    private func validate(budgets descriptor: AtlasIntegratorDescriptor, proposal: AtlasIntegrationProposal) throws {
        guard proposal.operations.count <= descriptor.maximumOperations else {
            throw AtlasIntegrationError.budgetExceeded
        }
        guard proposal.rationale.utf8.count <= descriptor.maximumProseBytes else {
            throw AtlasIntegrationError.budgetExceeded
        }
    }

    // MARK: - Exact consumption

    private func validate(consumption capture: AtlasIntegrationCapture, patch: AtlasPatch) throws {
        guard patch.watermarks == capture.watermarks else { throw AtlasIntegrationError.nonMonotonicConsumption }
        guard patch.claimedReportIDs == capture.pendingReports.map(\.id).sorted() else {
            throw AtlasIntegrationError.nonMonotonicConsumption
        }
        for watermark in capture.watermarks {
            guard watermark.sequence >= capture.state.watermark(for: watermark.shardID) else {
                throw AtlasIntegrationError.watermarkMismatch
            }
        }
    }

    // MARK: - Normalization

    private func normalize(
        item: AtlasItem,
        ascendantID: UUID,
        shards: [AscendantShardID: AscendantShard],
        pendingByOperation: [AtlasOperationID: AscendantShardReport],
        existing: [AtlasItemID: AtlasItem]
    ) throws -> AtlasItem {
        guard item.ascendantID == ascendantID else { throw AtlasIntegrationError.identityMismatch }
        guard item.provenance.ascendantID == ascendantID,
              item.provenance.shardID == item.sourceShardID else {
            throw AtlasIntegrationError.invalidProvenance
        }
        guard shards[item.sourceShardID] != nil else { throw AtlasIntegrationError.invalidReference }
        guard item.provenance.origin != .host else { throw AtlasIntegrationError.authorityViolation }
        guard item.epistemicStatus != .observed else { throw AtlasIntegrationError.invalidEpistemicStatus }

        let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= Self.maximumKeyBytes else { throw AtlasIntegrationError.invalidItemKey }
        try validate(applicability: item.applicability, disclosure: item.disclosure, shards: shards)

        let sourceReport = try sourceReport(for: item.provenance, in: pendingByOperation)
        if let sourceReport, sourceReport.shardID != item.sourceShardID {
            throw AtlasIntegrationError.inputMembership
        }

        let hostID = AtlasHostIdentity.itemID(ascendantID: ascendantID, key: key)
        let existingItem = existing[hostID]

        if item.lifecycle == .retracted || item.epistemicStatus == .retracted {
            guard item.lifecycle == .retracted, item.epistemicStatus == .retracted else {
                throw AtlasIntegrationError.invalidRetraction
            }
            guard let existingItem else { throw AtlasIntegrationError.invalidRetraction }
            guard existingItem.lifecycle != .retracted else { throw AtlasIntegrationError.invalidSupersession }
        } else {
            if existingItem == nil, item.lifecycle == .archived { throw AtlasIntegrationError.invalidLifecycle }
            if existingItem?.lifecycle == .retracted { throw AtlasIntegrationError.invalidSupersession }
        }

        return AtlasItem(
            id: hostID,
            ascendantID: ascendantID,
            sourceShardID: item.sourceShardID,
            key: key,
            value: item.value,
            kind: item.kind,
            applicability: item.applicability,
            disclosure: item.disclosure,
            epistemicStatus: item.epistemicStatus,
            lifecycle: item.lifecycle,
            provenance: provenance(
                ascendantID: ascendantID,
                shardID: item.sourceShardID,
                sourceReport: sourceReport
            )
        )
    }

    private func normalize(
        conflict: AtlasConflict,
        ascendantID: UUID,
        shards: [AscendantShardID: AscendantShard],
        pendingByOperation: [AtlasOperationID: AscendantShardReport],
        items: [AtlasItemID: AtlasItem],
        maximumProseBytes: Int
    ) throws -> AtlasConflict {
        guard conflict.ascendantID == ascendantID else { throw AtlasIntegrationError.identityMismatch }
        guard conflict.provenance.ascendantID == ascendantID,
              conflict.provenance.shardID == conflict.shardID else {
            throw AtlasIntegrationError.invalidProvenance
        }
        guard shards[conflict.shardID] != nil else { throw AtlasIntegrationError.invalidReference }
        guard conflict.provenance.origin != .host else { throw AtlasIntegrationError.authorityViolation }
        guard !conflict.itemIDs.isEmpty, conflict.itemIDs.allSatisfy({ items[$0] != nil }) else {
            throw AtlasIntegrationError.invalidReference
        }
        try validate(applicability: conflict.applicability, disclosure: conflict.disclosure, shards: shards)
        guard conflict.summary.utf8.count <= maximumProseBytes else { throw AtlasIntegrationError.budgetExceeded }

        let sourceReport = try sourceReport(for: conflict.provenance, in: pendingByOperation)
        if let sourceReport, sourceReport.shardID != conflict.shardID {
            throw AtlasIntegrationError.inputMembership
        }

        return AtlasConflict(
            id: AtlasHostIdentity.conflictID(
                ascendantID: ascendantID,
                shardID: conflict.shardID,
                itemIDs: conflict.itemIDs
            ),
            ascendantID: ascendantID,
            shardID: conflict.shardID,
            itemIDs: conflict.itemIDs,
            summary: conflict.summary,
            applicability: conflict.applicability,
            disclosure: conflict.disclosure,
            isResolved: conflict.isResolved,
            provenance: provenance(
                ascendantID: ascendantID,
                shardID: conflict.shardID,
                sourceReport: sourceReport
            )
        )
    }

    private func normalize(
        directive: AtlasDirective,
        ascendantID: UUID,
        shards: [AscendantShardID: AscendantShard],
        pendingByOperation: [AtlasOperationID: AscendantShardReport]
    ) throws -> AtlasDirective {
        guard directive.ascendantID == ascendantID else { throw AtlasIntegrationError.identityMismatch }
        guard directive.provenance.ascendantID == ascendantID else {
            throw AtlasIntegrationError.invalidProvenance
        }
        guard shards[directive.provenance.shardID] != nil else { throw AtlasIntegrationError.invalidReference }
        if let shardID = directive.shardID {
            guard shards[shardID] != nil, directive.provenance.shardID == shardID else {
                throw AtlasIntegrationError.invalidProvenance
            }
        }
        guard directive.provenance.origin != .host else { throw AtlasIntegrationError.authorityViolation }

        let key = directive.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= Self.maximumKeyBytes else { throw AtlasIntegrationError.invalidItemKey }
        try validate(applicability: directive.applicability, disclosure: directive.disclosure, shards: shards)

        let sourceReport = try sourceReport(for: directive.provenance, in: pendingByOperation)
        let provenanceShardID = directive.shardID ?? directive.provenance.shardID
        if let sourceReport, sourceReport.shardID != provenanceShardID {
            throw AtlasIntegrationError.inputMembership
        }

        return AtlasDirective(
            id: AtlasHostIdentity.directiveID(
                ascendantID: ascendantID,
                shardID: directive.shardID,
                key: key
            ),
            ascendantID: ascendantID,
            shardID: directive.shardID,
            key: key,
            value: directive.value,
            applicability: directive.applicability,
            disclosure: directive.disclosure,
            expiresAt: directive.expiresAt,
            isRevoked: directive.isRevoked,
            provenance: provenance(
                ascendantID: ascendantID,
                shardID: provenanceShardID,
                sourceReport: sourceReport
            )
        )
    }

    private func sourceReport(
        for provenance: AtlasProvenance,
        in pendingByOperation: [AtlasOperationID: AscendantShardReport]
    ) throws -> AscendantShardReport? {
        guard let operationID = provenance.operationID else { return nil }
        guard let report = pendingByOperation[operationID] else { throw AtlasIntegrationError.inputMembership }
        return report
    }

    private func provenance(
        ascendantID: UUID,
        shardID: AscendantShardID,
        sourceReport: AscendantShardReport?
    ) -> AtlasProvenance {
        AtlasProvenance(
            ascendantID: ascendantID,
            shardID: shardID,
            operationID: sourceReport?.operationID.rawValue,
            origin: .atlasIntegration,
            timelineID: sourceReport?.provenance.timelineID,
            workspaceIDs: sourceReport?.provenance.workspaceIDs ?? []
        )
    }

    // MARK: - Policy validation

    private func validate(
        applicability: AtlasApplicability,
        disclosure: AtlasDisclosure,
        shards: [AscendantShardID: AscendantShard]
    ) throws {
        if case let .shards(ids) = applicability, !ids.allSatisfy({ shards[$0] != nil }) {
            throw AtlasIntegrationError.invalidApplicability
        }
        if case let .shards(ids) = disclosure, !ids.allSatisfy({ shards[$0] != nil }) {
            throw AtlasIntegrationError.invalidDisclosure
        }
        let applicable = applicableShards(applicability, shards: shards)
        let disclosed = disclosedShards(disclosure, shards: shards)
        guard disclosed.isSubset(of: applicable) else { throw AtlasIntegrationError.invalidDisclosure }
    }

    private func applicableShards(
        _ applicability: AtlasApplicability,
        shards: [AscendantShardID: AscendantShard]
    ) -> Set<AscendantShardID> {
        switch applicability {
        case .none: []
        case .ascendant: Set(shards.keys)
        case let .shards(ids): Set(ids)
        }
    }

    private func disclosedShards(
        _ disclosure: AtlasDisclosure,
        shards: [AscendantShardID: AscendantShard]
    ) -> Set<AscendantShardID> {
        switch disclosure {
        case .none: []
        case .ascendant: Set(shards.keys)
        case let .shards(ids): Set(ids)
        }
    }

    // MARK: - Lifecycle helpers

    private func archived(_ item: AtlasItem) -> AtlasItem {
        AtlasItem(
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
    }

    private func resolved(_ conflict: AtlasConflict) -> AtlasConflict {
        AtlasConflict(
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
    }

    private func revoked(_ directive: AtlasDirective) -> AtlasDirective {
        AtlasDirective(
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
    }
}
