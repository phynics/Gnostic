// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import GnosticProtocol
import Testing

/// Axoloty 1.0.1 delivers every well-formed deadvertisement: unknown IDs, IDs that
/// aren't UUIDs, an empty list, and repeats. The catalog must stay correct for each.
@Suite("Network catalog deadvertisement")
struct NetworkCatalogDeadvertiseTests {
    private let owner = UUID().uuidString.lowercased()

    private func advertised(_ timelineID: UUID, workspaceID: UUID = UUID()) -> AdvertiseEventSnapshot {
        let payload = """
        {"protocolMajor":3,"objectId":"\(timelineID.uuidString.lowercased())","coreType":"CoatyObject","objectType":"\(GnosticObjectType.timeline)","name":"Remote timeline","title":"Remote timeline","isArchived":false,"attachedWorkspaceIDs":["\(workspaceID.uuidString.lowercased())"]}
        """
        return AdvertiseEventSnapshot(sourceId: owner, object: CoatyObjectSnapshot(
            objectId: timelineID.uuidString.lowercased(),
            coreType: .coatyObject,
            objectType: GnosticObjectType.timeline,
            name: "Remote timeline",
            payload: payload
        ))
    }

    /// The changes reported by `body`, ended by a provider eviction used as a marker.
    private func changes(
        in catalog: NetworkCatalog,
        during body: () async -> Void
    ) async -> [NetworkCatalogChange] {
        let stream = await catalog.changes()
        await body()
        let marker = UUID().uuidString.lowercased()
        await catalog.ingest(DeadvertiseEventSnapshot(sourceId: marker, objectIds: [marker]))
        var seen: [NetworkCatalogChange] = []
        for await change in stream {
            if case let .providerEvicted(id) = change, id == marker { break }
            seen.append(change)
        }
        return seen
    }

    @Test(
        "a deadvertisement that names nothing this source owns changes nothing",
        arguments: [[], ["not-a-uuid"], [UUID().uuidString]] as [[String]]
    )
    func unmatchedDeadvertisementIsIgnored(objectIDs: [String]) async {
        let catalog = NetworkCatalog()
        let timelineID = UUID()
        await catalog.ingest(advertised(timelineID))

        let seen = await changes(in: catalog) {
            await catalog.ingest(DeadvertiseEventSnapshot(sourceId: owner, objectIds: objectIDs))
        }

        #expect(seen.isEmpty)
        #expect(await catalog.networkObjects().map(\.objectID) == [timelineID])
    }

    @Test("a source can't remove another source's object")
    func anotherSourceCannotRemoveAnObject() async {
        let catalog = NetworkCatalog()
        let timelineID = UUID()
        await catalog.ingest(advertised(timelineID))

        let seen = await changes(in: catalog) {
            await catalog.ingest(DeadvertiseEventSnapshot(
                sourceId: UUID().uuidString.lowercased(),
                objectIds: [timelineID.uuidString]
            ))
        }

        #expect(seen.isEmpty)
        #expect(await catalog.networkObjects().map(\.objectID) == [timelineID])
    }

    @Test("a repeated object deadvertisement reports the removal once")
    func repeatedObjectDeadvertisement() async {
        let catalog = NetworkCatalog()
        let timelineID = UUID()
        await catalog.ingest(advertised(timelineID))

        let seen = await changes(in: catalog) {
            let event = DeadvertiseEventSnapshot(sourceId: owner, objectIds: [timelineID.uuidString])
            await catalog.ingest(event)
            await catalog.ingest(event)
        }

        #expect(seen.count == 1)
        #expect(await catalog.networkObjects().isEmpty)
    }

    @Test("a repeated identity deadvertisement, such as a clean stop then a broker will, leaves the catalog empty")
    func repeatedIdentityDeadvertisement() async {
        let catalog = NetworkCatalog()
        await catalog.ingest(advertised(UUID()))

        let event = DeadvertiseEventSnapshot(sourceId: owner, objectIds: [owner])
        await catalog.ingest(event)
        await catalog.ingest(event)

        #expect(await catalog.networkObjects().isEmpty)
    }

    @Test("an identity deadvertisement from a source never seen removes nothing it doesn't own")
    func unknownIdentityDeadvertisement() async {
        let catalog = NetworkCatalog()
        let timelineID = UUID()
        await catalog.ingest(advertised(timelineID))

        let stranger = UUID().uuidString.lowercased()
        await catalog.ingest(DeadvertiseEventSnapshot(sourceId: stranger, objectIds: [stranger]))

        #expect(await catalog.networkObjects().map(\.objectID) == [timelineID])
    }
}
