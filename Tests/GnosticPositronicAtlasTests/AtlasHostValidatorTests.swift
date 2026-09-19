// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

import GnosticPositronicAtlas

@Suite("Atlas host validation")
struct AtlasHostValidatorTests {
    private let ascendantID = UUID(uuidString: "A1170000-0000-4000-8000-000000000001")!
    private let timelineID = UUID(uuidString: "A1170000-0000-4000-8000-000000000002")!
    private let homeID = AscendantShardID(rawValue: UUID(uuidString: "A1170000-0000-4000-8000-000000000010")!)
    private let workID = AscendantShardID(rawValue: UUID(uuidString: "A1170000-0000-4000-8000-000000000020")!)
    private let unknownShardID = AscendantShardID(rawValue: UUID(uuidString: "A1170000-0000-4000-8000-0000000000FF")!)

    private let descriptor = AtlasIntegratorDescriptor(identifier: "atlas.test", version: "1")
    private let validator = AtlasHostValidator()

    // MARK: - Normalization

    @Test("a valid proposal is normalized with host identity and re-stamped provenance")
    func validProposalIsNormalized() async throws {
        let (store, report) = try await seeded()
        let capture = await store.capture()
        let proposal = AtlasIntegrationProposal(operations: [.upsertItem(AtlasItem(
            id: AtlasItemID(rawValue: UUID()),
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "response-style",
            value: .text("Prefer explicit schemas."),
            kind: .preference,
            applicability: .shards([workID]),
            disclosure: .shards([workID]),
            epistemicStatus: .reported,
            provenance: AtlasProvenance(
                ascendantID: ascendantID,
                shardID: homeID,
                operationID: "turn-1",
                origin: .atlasIntegration,
                timelineID: UUID()
            )
        ))])

        let validated = try validator.validate(descriptor: descriptor, capture: capture, proposal: proposal)

        let expectedID = AtlasHostIdentity.itemID(ascendantID: ascendantID, key: "response-style")
        let operation = try #require(validated.patch.operations.first)
        guard case let .upsertItem(item) = operation else {
            Issue.record("Expected an upsert item operation.")
            return
        }
        #expect(item.id == expectedID)
        #expect(item.provenance.origin == .atlasIntegration)
        #expect(item.provenance.operationID == report.operationID)
        #expect(item.provenance.timelineID == timelineID)
        #expect(item.ascendantID == ascendantID)

        #expect(validated.isSemantic)
        #expect(validated.consumedReportCount == 1)
        #expect(validated.patch.baseStateVersion == 0)
        #expect(validated.patch.captureID == capture.id)
        #expect(validated.patch.watermarks == capture.watermarks)
        #expect(validated.patch.claimedReportIDs == capture.pendingReports.map(\.id).sorted())
        #expect(validated.patch.provenance.origin == .host)
    }

    @Test("an empty proposal becomes a watermark-only no-op")
    func emptyProposalBecomesNoOp() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        let validated = try validator.validate(
            descriptor: descriptor,
            capture: capture,
            proposal: AtlasIntegrationProposal(operations: [])
        )

        #expect(validated.patch.operations == [.noOp])
        #expect(!validated.isSemantic)
        #expect(validated.consumedReportCount == 1)
    }

    // MARK: - Versions and budgets

    @Test("unsupported state and integrator versions are rejected")
    func unsupportedVersionsAreRejected() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()
        let proposal = AtlasIntegrationProposal(operations: [.noOp])

        let forgedState = AscendantAtlas(ascendantID: ascendantID, schemaVersion: 99)
        let forgedCapture = AtlasIntegrationCapture(
            id: AtlasCaptureID("forged"),
            state: forgedState,
            registrations: capture.registrations,
            watermarks: [],
            pendingReports: []
        )
        #expect(throws: AtlasIntegrationError.unsupportedStateSchema(expected: 1, actual: 99)) {
            _ = try validator.validate(descriptor: descriptor, capture: forgedCapture, proposal: proposal)
        }

        let forgedDescriptor = AtlasIntegratorDescriptor(identifier: "atlas.test", version: "1", schemaVersion: 7)
        #expect(throws: AtlasIntegrationError.unsupportedIntegratorSchema(expected: 1, actual: 7)) {
            _ = try validator.validate(descriptor: forgedDescriptor, capture: capture, proposal: proposal)
        }

        let emptyDescriptor = AtlasIntegratorDescriptor(identifier: "  ", version: "1")
        #expect(throws: AtlasIntegrationError.invalidIntegratorDescriptor) {
            _ = try validator.validate(descriptor: emptyDescriptor, capture: capture, proposal: proposal)
        }
    }

    @Test("budgets bound input reports, operations, and prose")
    func budgetsAreEnforced() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        let tinyInput = AtlasIntegratorDescriptor(
            identifier: "atlas.test",
            version: "1",
            maximumInputReports: 0
        )
        #expect(throws: AtlasIntegrationError.budgetExceeded) {
            _ = try validator.validate(
                descriptor: tinyInput,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.noOp])
            )
        }

        let tinyOps = AtlasIntegratorDescriptor(identifier: "atlas.test", version: "1", maximumOperations: 0)
        #expect(throws: AtlasIntegrationError.budgetExceeded) {
            _ = try validator.validate(
                descriptor: tinyOps,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.noOp, .noOp])
            )
        }

        let tinyProse = AtlasIntegratorDescriptor(identifier: "atlas.test", version: "1", maximumProseBytes: 3)
        #expect(throws: AtlasIntegrationError.budgetExceeded) {
            _ = try validator.validate(
                descriptor: tinyProse,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.noOp], rationale: "too long")
            )
        }
    }

    // MARK: - Authority and provenance

    @Test("host provenance and observed status are host-only authority")
    func hostAuthorityIsRejected() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        let hostOrigin = item(
            key: "host-claim",
            provenance: provenance(shardID: homeID, origin: .host, operationID: "turn-1")
        )
        #expect(throws: AtlasIntegrationError.authorityViolation) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(hostOrigin)])
            )
        }

        let observed = AtlasItem(
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "observed-claim",
            value: .text("direct"),
            epistemicStatus: .observed,
            provenance: provenance(shardID: homeID, origin: .atlasIntegration, operationID: "turn-1")
        )
        #expect(throws: AtlasIntegrationError.invalidEpistemicStatus) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(observed)])
            )
        }
    }

    @Test("inconsistent provenance and out-of-interval inputs are rejected")
    func provenanceAndMembershipAreRejected() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        let wrongShard = AtlasItem(
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: "mismatch",
            value: .text("v"),
            provenance: provenance(shardID: workID, origin: .atlasIntegration, operationID: "turn-1")
        )
        #expect(throws: AtlasIntegrationError.invalidProvenance) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(wrongShard)])
            )
        }

        let outsideInterval = item(
            key: "outside",
            provenance: provenance(shardID: homeID, origin: .atlasIntegration, operationID: "not-captured")
        )
        #expect(throws: AtlasIntegrationError.inputMembership) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(outsideInterval)])
            )
        }
    }

    // MARK: - Applicability and disclosure

    @Test("disclosure cannot broaden past applicability or unknown Shards")
    func disclosureIsConservative() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        let broadened = item(
            key: "broadened",
            applicability: .shards([homeID]),
            disclosure: .ascendant
        )
        #expect(throws: AtlasIntegrationError.invalidDisclosure) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(broadened)])
            )
        }

        let otherShard = item(key: "other-shard", disclosure: .shards([workID]))
        #expect(throws: AtlasIntegrationError.invalidDisclosure) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(otherShard)])
            )
        }

        let unknown = item(key: "unknown", applicability: .shards([unknownShardID]))
        #expect(throws: AtlasIntegrationError.invalidApplicability) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(unknown)])
            )
        }
    }

    // MARK: - Lifecycle, supersession, retraction

    @Test("lifecycle transitions are monotonic and retractions require accepted state")
    func lifecycleIsMonotonic() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        let prematureRetraction = item(key: "never-seen", lifecycle: .retracted, epistemicStatus: .retracted)
        #expect(throws: AtlasIntegrationError.invalidRetraction) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(prematureRetraction)])
            )
        }

        let archivedCreation = item(key: "never-seen", lifecycle: .archived)
        #expect(throws: AtlasIntegrationError.invalidLifecycle) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(archivedCreation)])
            )
        }

        let brokenPair = item(key: "pair", lifecycle: .retracted, epistemicStatus: .reported)
        #expect(throws: AtlasIntegrationError.invalidRetraction) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(brokenPair)])
            )
        }

        // Accept an item, then prove a retraction is allowed and resurrection is not.
        let first = item(key: "response-style")
        let firstValidated = try validator.validate(
            descriptor: descriptor,
            capture: capture,
            proposal: AtlasIntegrationProposal(operations: [.upsertItem(first)])
        )
        _ = try await store.compareAndSwap(capture: capture, patch: firstValidated.patch)

        let retractCapture = await store.capture()
        let retraction = item(key: "response-style", lifecycle: .retracted, epistemicStatus: .retracted)
        let retractValidated = try validator.validate(
            descriptor: descriptor,
            capture: retractCapture,
            proposal: AtlasIntegrationProposal(operations: [.upsertItem(retraction)])
        )
        _ = try await store.compareAndSwap(capture: retractCapture, patch: retractValidated.patch)

        let resurrectCapture = await store.capture()
        let resurrect = item(key: "response-style")
        #expect(throws: AtlasIntegrationError.invalidSupersession) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: resurrectCapture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(resurrect)])
            )
        }
    }

    // MARK: - Conflicts and directives

    @Test("conflicts reference accepted items and cannot reopen once resolved")
    func conflictsAreValidated() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()
        let first = item(key: "alpha")
        let validated = try validator.validate(
            descriptor: descriptor,
            capture: capture,
            proposal: AtlasIntegrationProposal(operations: [.upsertItem(first)])
        )
        _ = try await store.compareAndSwap(capture: capture, patch: validated.patch)

        let conflictCapture = await store.capture()
        guard let firstOperation = validated.patch.operations.first,
              case let .upsertItem(acceptedItem) = firstOperation else {
            Issue.record("Expected accepted item.")
            return
        }

        let unknownConflict = AtlasConflict(
            ascendantID: ascendantID,
            shardID: homeID,
            itemIDs: [AtlasItemID(rawValue: UUID())],
            summary: "unknown item",
            provenance: provenance(shardID: homeID, origin: .atlasIntegration)
        )
        #expect(throws: AtlasIntegrationError.invalidReference) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: conflictCapture,
                proposal: AtlasIntegrationProposal(operations: [.upsertConflict(unknownConflict)])
            )
        }

        let conflict = AtlasConflict(
            ascendantID: ascendantID,
            shardID: homeID,
            itemIDs: [acceptedItem.id],
            summary: "two readings",
            provenance: provenance(shardID: homeID, origin: .atlasIntegration)
        )
        let conflictValidated = try validator.validate(
            descriptor: descriptor,
            capture: conflictCapture,
            proposal: AtlasIntegrationProposal(operations: [.upsertConflict(conflict)])
        )
        _ = try await store.compareAndSwap(capture: conflictCapture, patch: conflictValidated.patch)
        let acceptedConflictID = AtlasHostIdentity.conflictID(
            ascendantID: ascendantID,
            shardID: homeID,
            itemIDs: [acceptedItem.id]
        )

        let resolveCapture = await store.capture()
        let reopen = AtlasConflict(
            id: acceptedConflictID,
            ascendantID: ascendantID,
            shardID: homeID,
            itemIDs: [acceptedItem.id],
            summary: "two readings",
            isResolved: false,
            provenance: provenance(shardID: homeID, origin: .atlasIntegration)
        )
        #expect(throws: AtlasIntegrationError.invalidConflict) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: resolveCapture,
                proposal: AtlasIntegrationProposal(operations: [
                    .resolveConflict(acceptedConflictID),
                    .upsertConflict(reopen),
                ])
            )
        }
    }

    @Test("directives are validated, revocable, and not resurrectable")
    func directivesAreValidated() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        let revokeUnknown = AtlasDirectiveID(rawValue: UUID())
        #expect(throws: AtlasIntegrationError.invalidReference) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.revokeDirective(revokeUnknown)])
            )
        }

        let preRevoked = directive(key: "pre-revoked", isRevoked: true)
        #expect(throws: AtlasIntegrationError.invalidDirective) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertDirective(preRevoked)])
            )
        }

        let fresh = directive(key: "guidance")
        let validated = try validator.validate(
            descriptor: descriptor,
            capture: capture,
            proposal: AtlasIntegrationProposal(operations: [.upsertDirective(fresh)])
        )
        _ = try await store.compareAndSwap(capture: capture, patch: validated.patch)

        guard let firstOperation = validated.patch.operations.first,
              case let .upsertDirective(accepted) = firstOperation else {
            Issue.record("Expected accepted directive.")
            return
        }
        #expect(accepted.id == AtlasHostIdentity.directiveID(ascendantID: ascendantID, shardID: nil, key: "guidance"))

        let revokeCapture = await store.capture()
        _ = try await store.compareAndSwap(
            capture: revokeCapture,
            patch: try validator.validate(
                descriptor: descriptor,
                capture: revokeCapture,
                proposal: AtlasIntegrationProposal(operations: [.revokeDirective(accepted.id)])
            ).patch
        )

        let reviveCapture = await store.capture()
        #expect(throws: AtlasIntegrationError.invalidDirective) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: reviveCapture,
                proposal: AtlasIntegrationProposal(operations: [.upsertDirective(fresh)])
            )
        }
    }

    // MARK: - Duplicates and keys

    @Test("duplicate addresses and invalid keys are rejected")
    func duplicatesAndKeysAreRejected() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()

        #expect(throws: AtlasIntegrationError.duplicateOperation) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [
                    .upsertItem(item(key: "same")),
                    .upsertItem(item(key: "same")),
                ])
            )
        }

        #expect(throws: AtlasIntegrationError.invalidItemKey) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: capture,
                proposal: AtlasIntegrationProposal(operations: [.upsertItem(item(key: "   "))])
            )
        }
    }

    @Test("a malformed captured cut is rejected before normalization")
    func malformedCaptureIsRejected() async throws {
        let (store, _) = try await seeded()
        let capture = await store.capture()
        let regressed = AtlasIntegrationCapture(
            id: AtlasCaptureID("regressed"),
            state: capture.state,
            registrations: capture.registrations,
            watermarks: [AtlasWatermark(shardID: homeID, sequence: 0)],
            pendingReports: capture.pendingReports
        )
        #expect(throws: AtlasIntegrationError.watermarkMismatch) {
            _ = try validator.validate(
                descriptor: descriptor,
                capture: regressed,
                proposal: AtlasIntegrationProposal(operations: [.noOp])
            )
        }
    }

    // MARK: - Helpers

    private func seeded() async throws -> (InMemoryAtlasStore, AscendantShardReport) {
        let store = InMemoryAtlasStore(ascendantID: ascendantID)
        _ = try await store.register(AscendantShard(id: homeID, ascendantID: ascendantID, name: "Home"))
        _ = try await store.register(AscendantShard(id: workID, ascendantID: ascendantID, name: "Work"))
        let append = try await store.append(ShardReportDraft(
            ascendantID: ascendantID,
            shardID: homeID,
            operationID: "turn-1",
            content: "bounded report",
            provenance: AtlasProvenance(
                ascendantID: ascendantID,
                shardID: homeID,
                operationID: "turn-1",
                origin: .ascendantTurn,
                timelineID: timelineID,
                workspaceIDs: [UUID(uuidString: "A1170000-0000-4000-8000-000000000077")!]
            )
        ))
        return (store, append.report)
    }

    private func item(
        key: String,
        applicability: AtlasApplicability = .none,
        disclosure: AtlasDisclosure = .none,
        lifecycle: AtlasItemLifecycle = .active,
        epistemicStatus: AtlasEpistemicStatus = .reported,
        provenance: AtlasProvenance? = nil
    ) -> AtlasItem {
        AtlasItem(
            ascendantID: ascendantID,
            sourceShardID: homeID,
            key: key,
            value: .text("value for \(key)"),
            kind: .preference,
            applicability: applicability,
            disclosure: disclosure,
            epistemicStatus: epistemicStatus,
            lifecycle: lifecycle,
            provenance: provenance ?? self.provenance(shardID: homeID, origin: .atlasIntegration)
        )
    }

    private func directive(key: String, isRevoked: Bool = false) -> AtlasDirective {
        AtlasDirective(
            ascendantID: ascendantID,
            key: key,
            value: .text("value for \(key)"),
            isRevoked: isRevoked,
            provenance: provenance(shardID: homeID, origin: .atlasIntegration)
        )
    }

    private func provenance(
        shardID: AscendantShardID,
        origin: AtlasOrigin,
        operationID: String? = nil
    ) -> AtlasProvenance {
        AtlasProvenance(
            ascendantID: ascendantID,
            shardID: shardID,
            operationID: operationID,
            origin: origin
        )
    }
}
