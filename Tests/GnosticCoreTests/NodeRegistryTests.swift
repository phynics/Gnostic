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

        let created = try await registry.registerRuntimeTimeline(title: "Runtime", ascendantID: fixture.ascendantID)
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

    @Test("concurrent runtime Timeline creation preserves identity and requested operator")
    func concurrentCreationIsAtomic() async throws {
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])

        let created = await withTaskGroup(of: NodeRegistry.TimelineRecord.self, returning: [NodeRegistry.TimelineRecord].self) { group in
            for index in 0..<32 {
                group.addTask { try! await registry.registerRuntimeTimeline(title: "Runtime \(index)", ascendantID: fixture.ascendantID) }
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

    @Test("a failed required projection restores the accepted Timeline record")
    func projectionFailureCompensatesRegistryMutation() async throws {
        struct ProjectionFailure: Error {}
        let fixture = try Fixture()
        let registry = try NodeRegistry(plan: fixture.plan, operatedTimelines: [fixture.operated])
        let renamed = AscendantRuntimeTimeline(
            id: fixture.operated.id,
            title: "Rejected rename",
            attachedWorkspaceIDs: fixture.operated.attachedWorkspaceIDs,
            attachedAgentInstanceID: fixture.operated.attachedAgentInstanceID,
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
            attachedAgentInstanceID: fixture.operated.attachedAgentInstanceID,
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

    private struct Fixture: Sendable {
        let ascendantID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000001")!
        let operatedID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000002")!
        let unoperatedID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000003")!
        let networkWorkspaceID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000004")!
        let operated: AscendantRuntimeTimeline
        let unoperated: AscendantRuntimeTimeline
        let plan: NodeLaunchPlan

        init() throws {
            let now = Date(timeIntervalSince1970: 1)
            operated = .init(id: operatedID, title: "Operated", attachedWorkspaceIDs: [networkWorkspaceID], attachedAgentInstanceID: ascendantID, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
            unoperated = .init(id: unoperatedID, title: "Unoperated", attachedWorkspaceIDs: [], attachedAgentInstanceID: nil, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
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
