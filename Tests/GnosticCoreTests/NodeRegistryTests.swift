// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCore

@Suite("Canonical node registry")
struct NodeRegistryTests {
    @Test("snapshot, list, status, routing, and discovery share accepted Timeline state")
    func acceptedTimelineStateDrivesEveryReadModel() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let lease = UUID()
        await registry.activateBackendLease(lease, for: fixture.ascendantID)

        let created = try await registry.registerRuntimeTimeline(
            fixture.runtimeTimeline(title: "Runtime"),
            ascendantID: fixture.ascendantID,
            backendLease: lease
        )
        let snapshot = await registry.snapshot()
        let listed = await registry.listTimelines()
        let discoverable = await registry.discoverableTimelineIDs()

        let expected = Set([fixture.operated.id, fixture.unoperated.id, created.id])
        #expect(Set(snapshot.timelineIDs) == expected)
        #expect(Set(listed.map(\.id)) == expected)
        #expect(Set(discoverable) == expected)
        #expect(await registry.timeline(id: fixture.unoperated.id)?.operatorID == nil)
        #expect(await registry.operatorID(forTimeline: fixture.operated.id) == fixture.ascendantID)
        #expect(await registry.operatorID(forTimeline: created.id) == fixture.ascendantID)
    }

    @Test("duplicate adapter Timeline projections fail structurally instead of trapping")
    func duplicateAdapterTimelineProjectionIsRejected() throws {
        let fixture = try Fixture()

        #expect(throws: NodeRuntimeError.missingTimeline(fixture.operated.id)) {
            _ = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated, fixture.operated])
        }
    }

    @Test("a persisted runtime Timeline is adopted on restart")
    func persistedRuntimeTimelineIsAdopted() async throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 2)
        let runtimeID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000006")!
        let persisted = AscendantRuntimeTimeline(
            id: runtimeID,
            title: "Runtime",
            attachedWorkspaceIDs: [],
            runtimeInstanceID: fixture.ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )

        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated, persisted])
        #expect(await registry.timeline(id: runtimeID)?.provenance == .runtime)
        #expect(await registry.operatorID(forTimeline: runtimeID) == fixture.ascendantID)
        #expect(await registry.attachmentIntent(for: runtimeID).isEmpty)
        #expect(await registry.snapshot().operatedTimelineIDs.contains(runtimeID))
    }

    @Test("a restart rebuilds a runtime Timeline title and Workspace intent from its journal")
    func journalRebuildsRuntimeTimelineProjection() async throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("node-registry-timeline-journal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let writer = TimelineJournalStore(directoryURL: directory)
        let registry = try NodeRegistry(
            plan: fixture.plan,
            operatedTimelines: [fixture.operated],
            timelineJournals: writer
        )
        let lease = UUID()
        await registry.activateBackendLease(lease, for: fixture.ascendantID)
        let created = try await registry.registerRuntimeTimeline(
            fixture.runtimeTimeline(title: "Before rename"),
            ascendantID: fixture.ascendantID,
            backendLease: lease
        )
        let attached = AscendantRuntimeTimeline(
            id: created.id,
            title: "After rename",
            attachedWorkspaceIDs: [fixture.networkWorkspaceID],
            runtimeInstanceID: fixture.ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: created.timeline.createdAt,
            updatedAt: Date()
        )
        _ = try await registry.commitBackendTimeline(
            attached,
            ascendantID: fixture.ascendantID,
            backendLease: lease,
            upserting: .network(fixture.networkWorkspaceID, uri: "workspace://expected")
        )

        let reader = TimelineJournalStore(directoryURL: directory)
        let projections = try await reader.timelineProjections()
        let restarted = try NodeRegistry(
            plan: fixture.plan,
            operatedTimelines: [fixture.operated],
            timelineJournals: reader,
            timelineJournalProjections: projections
        )
        let restored = try #require(await restarted.timeline(id: created.id))
        #expect(restored.timeline.title == "After rename")
        #expect(restored.timeline.attachedWorkspaceIDs == [fixture.networkWorkspaceID])
        #expect(await restarted.attachmentIntent(for: created.id) == [
            .network(fixture.networkWorkspaceID, uri: "workspace://expected")
        ])
    }

    @Test("concurrent runtime Timeline creation preserves identity and requested operator")
    func concurrentCreationIsAtomic() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let lease = UUID()
        await registry.activateBackendLease(lease, for: fixture.ascendantID)
        let pending = (0..<32).map { fixture.runtimeTimeline(title: "Runtime \($0)") }

        let created = await withTaskGroup(of: NodeRegistry.TimelineRecord.self, returning: [NodeRegistry.TimelineRecord].self) { group in
            for timeline in pending {
                group.addTask { try! await registry.registerRuntimeTimeline(timeline, ascendantID: fixture.ascendantID, backendLease: lease) }
            }
            var records: [NodeRegistry.TimelineRecord] = []
            for await record in group { records.append(record) }
            return records
        }

        #expect(Set(created.map(\.id)).count == 32)
        #expect(created.allSatisfy { $0.provenance == .runtime && $0.operatorID == fixture.ascendantID })
        #expect(await registry.snapshot().timelineIDs.count == 34)
    }

    @Test("unoperated Timelines are discoverable but have no chat or Workspace mutation route")
    func unoperatedTimelineHasNoMutationRoute() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])

        #expect(await registry.discoverableTimelineIDs().contains(fixture.unoperated.id))
        #expect(await registry.operatorID(forTimeline: fixture.unoperated.id) == nil)
        await #expect(throws: NodeRuntimeError.noOperatingAscendant(fixture.unoperated.id)) {
            try await registry.requireOperatingAscendant(for: fixture.unoperated.id)
        }
    }

    @Test("lazy Workspace availability retains the configured identity and URI guard")
    func lazyWorkspaceResolutionPreservesConfiguredIdentity() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let unresolved = try #require(await registry.workspace(id: fixture.networkWorkspaceID))

        #expect(unresolved.uri == "workspace://expected")
        #expect(unresolved.isAvailable == false)
        #expect(try await registry.resolveLazyWorkspace(id: fixture.networkWorkspaceID, uri: "workspace://wrong", toolIDs: ["wrong"]) == false)
        #expect(await registry.workspace(id: fixture.networkWorkspaceID) == unresolved)
        #expect(try await registry.resolveLazyWorkspace(id: fixture.networkWorkspaceID, uri: "workspace://expected", toolIDs: ["remote_echo"]))
        let resolved = try #require(await registry.workspace(id: fixture.networkWorkspaceID))
        #expect(resolved.id == fixture.networkWorkspaceID)
        #expect(resolved.uri == "workspace://expected")
        #expect(resolved.isAvailable)
        #expect(resolved.toolIDs == ["remote_echo"])
    }

    @Test("runtime attachment intent is authoritative across attach and detach")
    func runtimeAttachmentIntentTracksMutations() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let lease = UUID()
        await registry.activateBackendLease(lease, for: fixture.ascendantID)
        let runtime = try await registry.registerRuntimeTimeline(
            fixture.runtimeTimeline(title: "Runtime"),
            ascendantID: fixture.ascendantID,
            backendLease: lease
        )

        #expect(await registry.attachmentIntent(for: runtime.id).isEmpty)
        try await registry.upsertAttachmentIntent(.network(fixture.networkWorkspaceID, uri: "workspace://expected"), for: runtime.id)
        #expect(await registry.attachmentIntent(for: runtime.id) == [.network(fixture.networkWorkspaceID, uri: "workspace://expected")])
        try await registry.removeAttachmentIntent(workspaceID: fixture.networkWorkspaceID, from: runtime.id)
        #expect(await registry.attachmentIntent(for: runtime.id).isEmpty)
    }

    @Test("a restart seeds an unresolved Workspace record for each journal-recovered network attachment")
    func recoveredNetworkAttachmentSeedsUnresolvedWorkspace() async throws {
        let fixture = try Fixture()
        let journal = try await RecoveredJournal(fixture: fixture)
        let dynamicID = UUID()
        let second = try await journal.createTimeline(title: "Second")
        let first = try await journal.createTimeline(title: "First")
        try await journal.attach(.network(dynamicID, uri: "workspace://dynamic"), to: first)
        // A second Timeline attaching the same Workspace adds no second record.
        try await journal.attach(.network(dynamicID, uri: "workspace://dynamic"), to: second)

        let restarted = try await journal.restart()
        let record = try #require(await restarted.workspace(id: dynamicID))
        #expect(record.uri == "workspace://dynamic")
        #expect(record.isAvailable == false)
        #expect(record.toolIDs.isEmpty)
        #expect(await restarted.unresolvedWorkspaceIDs().filter { $0 == dynamicID }.count == 1)
        #expect(await restarted.snapshot().workspaceIDs.filter { $0 == dynamicID }.count == 1)
        #expect(Set(await restarted.attachmentTargets(for: dynamicID).map(\.timelineID)) == [first, second])
    }

    @Test("a recovered attachment agrees with the manifest attachment of the same Workspace")
    func recoveredAttachmentDoesNotConflictWithManifestAttachment() async throws {
        let fixture = try Fixture()
        let journal = try await RecoveredJournal(fixture: fixture)
        let timelineID = try await journal.createTimeline(title: "Recovered")
        try await journal.attach(.network(fixture.networkWorkspaceID, uri: "workspace://expected"), to: timelineID)

        let restarted = try await journal.restart()
        let record = try #require(await restarted.workspace(id: fixture.networkWorkspaceID))
        #expect(record.uri == "workspace://expected")
        #expect(await restarted.unresolvedWorkspaceIDs().filter { $0 == fixture.networkWorkspaceID }.count == 1)
        #expect(await restarted.attachmentTargets(for: fixture.networkWorkspaceID).count == 2)
    }

    @Test("a recovered attachment with another URI than the configured record is ignored and the registry starts")
    func recoveredAttachmentURIConflictKeepsTheConfiguredRecord() async throws {
        let fixture = try Fixture()
        let journal = try await RecoveredJournal(fixture: fixture)
        let timelineID = try await journal.createTimeline(title: "Conflict")
        try await journal.attach(.network(fixture.networkWorkspaceID, uri: "workspace://other"), to: timelineID)

        let restarted = try await journal.restart()
        let record = try #require(await restarted.workspace(id: fixture.networkWorkspaceID))
        #expect(record.uri == "workspace://expected")
        let conflict = try #require(await restarted.attachmentConflict(timelineID: timelineID, workspaceID: fixture.networkWorkspaceID))
        #expect(conflict.attachedURI == "workspace://other")
        #expect(conflict.recordedURI == "workspace://expected")
        #expect(await restarted.recoveredAttachmentConflicts() == [conflict])
        for expected in [fixture.networkWorkspaceID.uuidString, timelineID.uuidString, "workspace://other", "workspace://expected"] {
            #expect(conflict.warning.contains(expected))
        }
        // The conflicted Timeline never resolves the Workspace. Its intent stays so a detach can remove it.
        #expect(await restarted.attachmentTargets(for: fixture.networkWorkspaceID).map(\.timelineID) == [fixture.operatedID])
        #expect(await restarted.attachmentIntent(for: timelineID) == [.network(fixture.networkWorkspaceID, uri: "workspace://other")])

        try await restarted.removeAttachmentIntent(workspaceID: fixture.networkWorkspaceID, from: timelineID)
        #expect(await restarted.attachmentIntent(for: timelineID).isEmpty)
        #expect(await restarted.recoveredAttachmentConflicts().isEmpty)
    }

    @Test("two conflicting recovered attachments resolve to the lower Timeline UUID")
    func conflictingRecoveredAttachmentsResolveDeterministically() async throws {
        let fixture = try Fixture()
        let journal = try await RecoveredJournal(fixture: fixture)
        let dynamicID = UUID()
        let low = UUID(uuidString: "C21D0000-0000-4000-8000-000000000001")!
        let high = UUID(uuidString: "C21D0000-0000-4000-8000-000000000002")!
        // Journal the later-sorting Timeline first, so file order cannot decide.
        _ = try await journal.createTimeline(id: high, title: "High")
        _ = try await journal.createTimeline(id: low, title: "Low")
        try await journal.attach(.network(dynamicID, uri: "workspace://from-high"), to: high)
        try await journal.attach(.network(dynamicID, uri: "workspace://from-low"), to: low)

        let restarted = try await journal.restart()
        #expect(await restarted.workspace(id: dynamicID)?.uri == "workspace://from-low")
        let conflict = try #require(await restarted.recoveredAttachmentConflicts().first)
        #expect(await restarted.recoveredAttachmentConflicts().count == 1)
        #expect(conflict.timelineID == high)
        #expect(conflict.attachedURI == "workspace://from-high")
        #expect(conflict.recordedURI == "workspace://from-low")
        #expect(await restarted.attachmentTargets(for: dynamicID).map(\.timelineID) == [low])
    }

    @Test("two manifest attachments that name one Workspace with different URIs still fail startup")
    func conflictingManifestAttachmentsFailStartup() throws {
        let fixture = try Fixture()
        let plan = try NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-registry-tests"),
            node: .init(id: UUID()),
            ascendants: [.init(id: fixture.ascendantID, name: "Registry", defaultTimelineID: fixture.operatedID)],
            timelines: [
                .init(id: fixture.operatedID, title: "A", operatingAscendantID: fixture.ascendantID, attachments: [.network(fixture.networkWorkspaceID, uri: "workspace://one")]),
                .init(id: fixture.unoperatedID, title: "B", attachments: [.network(fixture.networkWorkspaceID, uri: "workspace://two")]),
            ]
        ).compileLaunchPlan()

        #expect(throws: NodeRuntimeError.invalidWorkspaceURI(fixture.networkWorkspaceID)) {
            _ = try NodeRegistry(plan: plan, operatedTimelines: [fixture.operated])
        }
    }

    @Test("a detached Workspace is not seeded after restart")
    func detachedWorkspaceIsNotRecovered() async throws {
        let fixture = try Fixture()
        let journal = try await RecoveredJournal(fixture: fixture)
        let dynamicID = UUID()
        let timelineID = try await journal.createTimeline(title: "Detached")
        try await journal.attach(.network(dynamicID, uri: "workspace://dynamic"), to: timelineID)
        try await journal.detach(dynamicID, from: timelineID)

        let restarted = try await journal.restart()
        #expect(await restarted.workspace(id: dynamicID) == nil)
        #expect(await restarted.unresolvedWorkspaceIDs().contains(dynamicID) == false)
        #expect(await restarted.attachmentTargets(for: dynamicID).isEmpty)
    }

    @Test("a manifest attachment the journal detached does not come back after restart")
    func journalDetachedManifestAttachmentStaysDetached() async throws {
        let fixture = try Fixture()
        let journal = try await RecoveredJournal(fixture: fixture)
        try await journal.recordConfiguredTimeline()
        try await journal.detach(fixture.networkWorkspaceID, from: fixture.operatedID)

        let restarted = try await journal.restart()
        #expect(await restarted.attachmentIntent(for: fixture.operatedID).isEmpty)
        #expect(await restarted.timeline(id: fixture.operatedID)?.timeline.attachedWorkspaceIDs.isEmpty == true)
        #expect(await restarted.workspace(id: fixture.networkWorkspaceID) == nil)
        #expect(await restarted.unresolvedWorkspaceIDs().contains(fixture.networkWorkspaceID) == false)
        #expect(await restarted.attachmentTargets(for: fixture.networkWorkspaceID).isEmpty)
    }

    @Test("a recovered local attachment seeds no network Workspace record")
    func recoveredLocalAttachmentIsNotSeeded() async throws {
        let fixture = try Fixture()
        let journal = try await RecoveredJournal(fixture: fixture)
        let localID = UUID()
        let timelineID = try await journal.createTimeline(title: "Local")
        try await journal.attach(.local(localID), to: timelineID)

        let restarted = try await journal.restart()
        #expect(await restarted.attachmentIntent(for: timelineID) == [.local(localID)])
        #expect(await restarted.workspace(id: localID) == nil)
    }

    @Test("a failed required projection restores the accepted Timeline record")
    func projectionFailureCompensatesRegistryMutation() async throws {
        struct ProjectionFailure: Error {}
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let renamed = AscendantRuntimeTimeline(
            id: fixture.operated.id,
            title: "Rejected rename",
            attachedWorkspaceIDs: fixture.operated.attachedWorkspaceIDs,
            runtimeInstanceID: fixture.operated.runtimeInstanceID,
            isArchived: fixture.operated.isArchived,
            isPrivate: fixture.operated.isPrivate,
            createdAt: fixture.operated.createdAt,
            updatedAt: Date()
        )

        await #expect(throws: ProjectionFailure.self) {
            try await registry.replaceTimeline(renamed) { _ in throw ProjectionFailure() }
        }

        #expect(await registry.timeline(id: fixture.operated.id)?.timeline.title == "Operated")
    }

    @Test("an accepted mutation emits exactly one matching projection")
    func acceptedMutationProjectsExactlyOnce() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let recorder = ProjectionRecorder()
        let renamed = AscendantRuntimeTimeline(
            id: fixture.operated.id,
            title: "Accepted rename",
            attachedWorkspaceIDs: fixture.operated.attachedWorkspaceIDs,
            runtimeInstanceID: fixture.operated.runtimeInstanceID,
            isArchived: fixture.operated.isArchived,
            isPrivate: fixture.operated.isPrivate,
            createdAt: fixture.operated.createdAt,
            updatedAt: Date()
        )

        _ = try await registry.replaceTimeline(renamed) { recorder.record($0) }

        #expect(recorder.records == [NodeRegistry.TimelineRecord(
            timeline: renamed,
            operatorID: fixture.ascendantID,
            provenance: .configured
        )])
        #expect(await registry.timeline(id: renamed.id)?.timeline == renamed)
    }

    @Test("a stale backend lease cannot mutate canonical Timeline state")
    func staleBackendLeaseCannotMutateCanonicalState() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let liveLease = UUID()
        let staleLease = UUID()
        await registry.activateBackendLease(liveLease, for: fixture.ascendantID)

        await #expect(throws: NodeRuntimeError.notRunning) {
            _ = try await registry.registerRuntimeTimeline(
                fixture.runtimeTimeline(title: "Stale runtime"),
                ascendantID: fixture.ascendantID,
                backendLease: staleLease
            )
        }
        await #expect(throws: NodeRuntimeError.notRunning) {
            _ = try await registry.commitBackendTimeline(
                fixture.operated,
                ascendantID: fixture.ascendantID,
                backendLease: staleLease
            )
        }
        #expect(await registry.timeline(id: fixture.operated.id)?.timeline.title == "Operated")
        #expect(await registry.listTimelines().count == 2)
    }

    /// A Node journal on disk that the test restarts a registry from, the way
    /// `gnostic serve` rebuilds its registry from the journal.
    private struct RecoveredJournal {
        let fixture: Fixture
        let directory: URL
        let registry: NodeRegistry
        let journals: TimelineJournalStore
        let lease = UUID()

        init(fixture: Fixture) async throws {
            self.fixture = fixture
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("node-registry-recovered-workspace-tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            journals = TimelineJournalStore(directoryURL: directory)
            registry = try NodeRegistry(
                plan: fixture.plan,
                operatedTimelines: [fixture.operated],
                timelineJournals: journals
            )
            await registry.activateBackendLease(lease, for: fixture.ascendantID)
        }

        /// Journals the configured operated Timeline the way `gnostic serve` does at launch.
        func recordConfiguredTimeline() async throws {
            try await journals.ensureTimelineCreated(
                timelineID: fixture.operatedID,
                title: "Operated",
                runtimeInstanceID: fixture.ascendantID,
                attachments: [.network(fixture.networkWorkspaceID, uri: "workspace://expected")]
            )
        }

        func createTimeline(id: UUID = UUID(), title: String) async throws -> UUID {
            try await registry.registerRuntimeTimeline(
                fixture.runtimeTimeline(id: id, title: title),
                ascendantID: fixture.ascendantID,
                backendLease: lease
            ).id
        }

        func attach(_ attachment: NodeManifest.WorkspaceAttachment, to timelineID: UUID) async throws {
            try await registry.upsertAttachmentIntent(attachment, for: timelineID)
        }

        func detach(_ workspaceID: UUID, from timelineID: UUID) async throws {
            try await registry.removeAttachmentIntent(workspaceID: workspaceID, from: timelineID)
        }

        func restart() async throws -> NodeRegistry {
            let reader = TimelineJournalStore(directoryURL: directory)
            return try NodeRegistry(
                plan: fixture.plan,
                operatedTimelines: [fixture.operated],
                timelineJournals: reader,
                timelineJournalProjections: try await reader.timelineProjections()
            )
        }
    }

    private struct Fixture: Sendable {
        let ascendantID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000001")!
        let operatedID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000002")!
        let unoperatedID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000003")!
        let networkWorkspaceID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000004")!
        let operated: AscendantRuntimeTimeline
        let unoperated: AscendantRuntimeTimeline
        let plan: NodeLaunchPlan

        /// Builds a runtime Timeline under this fixture's Ascendant.
        func runtimeTimeline(id: UUID = UUID(), title: String) -> AscendantRuntimeTimeline {
            let now = Date()
            return .init(
                id: id,
                title: title,
                attachedWorkspaceIDs: [],
                runtimeInstanceID: ascendantID,
                isArchived: false,
                isPrivate: false,
                createdAt: now,
                updatedAt: now
            )
        }

        init() throws {
            let now = Date(timeIntervalSince1970: 1)
            operated = .init(id: operatedID, title: "Operated", attachedWorkspaceIDs: [networkWorkspaceID], runtimeInstanceID: ascendantID, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
            unoperated = .init(id: unoperatedID, title: "Unoperated", attachedWorkspaceIDs: [], runtimeInstanceID: nil, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
            plan = try NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "node-registry-tests"),
                node: .init(id: UUID(uuidString: "B21D0000-0000-4000-8000-000000000005")!),
                ascendants: [.init(id: ascendantID, name: "Registry", defaultTimelineID: operatedID)],
                timelines: [
                    .init(id: operatedID, title: "Operated", operatingAscendantID: ascendantID, attachments: [.network(networkWorkspaceID, uri: "workspace://expected")]),
                    .init(id: unoperatedID, title: "Unoperated"),
                ]
            ).compileLaunchPlan()
        }
    }
}

private final class ProjectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NodeRegistry.TimelineRecord] = []

    var records: [NodeRegistry.TimelineRecord] { lock.withLock { storage } }
    func record(_ record: NodeRegistry.TimelineRecord) { lock.withLock { storage.append(record) } }
}
