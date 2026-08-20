// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import Testing

@Suite("Gnostic protocol v2 contract")
struct ProtocolV2Tests {
    private let ascendantID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000001")!
    private let timelineID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000002")!

    @Test("Ascendant projections carry the v2 major and use the new wire type")
    func ascendantProjectionUsesV2Contract() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = AscendantRuntimeIdentity(
            id: ascendantID,
            name: "Atlas",
            description: "Coordinates analysis.",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now
        )

        let object = GnosticAscendantObject(identity: identity)

        #expect(object.objectType == GnosticObjectType.ascendant)
        #expect(object.protocolMajor == GnosticProtocol.currentMajor)
        let data = try JSONEncoder().encode(object)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"protocolMajor\":\(GnosticProtocol.currentMajor)"))
        #expect(!json.contains("me.atkn.gnostic.Agent"))
    }

    @Test("Turn requests, results, replay updates, and errors carry the protocol major")
    func turnPayloadsCarryProtocolMajor() throws {
        let request = AscendantTurnRequest(
            message: "hello",
            timelineID: timelineID,
            clientTurnID: "turn-1"
        )
        let result = AscendantTurnResult(clientTurnID: "turn-1", text: "world")
        let update = AscendantTurnUpdate(sequence: 1, kind: "completion", text: "world", terminal: true)
        let replay = AscendantTurnReplay(updates: [update], compacted: false, terminal: true)

        #expect(request.protocolMajor == GnosticProtocol.currentMajor)
        #expect(result.protocolMajor == GnosticProtocol.currentMajor)
        #expect(update.protocolMajor == GnosticProtocol.currentMajor)
        #expect(replay.protocolMajor == GnosticProtocol.currentMajor)
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] != nil)
    }

    @Test("unsupported turn majors are rejected at the direct call seam")
    func directCallRevalidatesProtocolMajor() async throws {
        let provider = AscendantTurnProvider { request in
            AscendantTurnResult(clientTurnID: request.clientTurnID, text: request.message)
        }
        let payload = #"{"message":"hello","timelineID":"B21D0000-0000-4000-8000-000000000002","clientTurnID":"turn-1","protocolMajor":1}"#

        let response = try await provider.handle(parameters: payload)
        guard case let .failure(code, message, _) = response else {
            Issue.record("unsupported protocol major unexpectedly succeeded")
            return
        }
        #expect(code == 426)
        #expect(message.contains("unsupportedProtocolMajor"))
    }

    @Test("workspace direct calls report missing protocol majors structurally")
    func workspaceDirectCallReportsMissingProtocolMajor() async throws {
        let id = UUID()
        let provider = WorkspaceProvider(workspaceID: id, tools: []) { _, _ in .success("unused") }
        let response = try await provider.handle(parameters: "{}")
        guard case let .failure(code, message, _) = response else {
            Issue.record("missing protocol major unexpectedly succeeded")
            return
        }
        #expect(code == 400)
        #expect(message.contains("missingProtocolMajor"))
    }

    @Test("management and workspace payload decoders require the protocol major")
    func managementPayloadDecodersRequireProtocolMajor() throws {
        let timeline = #"{"timelineID":"B21D0000-0000-4000-8000-000000000002"}"#
        let workspace = #"{"workspaceID":"B21D0000-0000-4000-8000-000000000001","timelineID":"B21D0000-0000-4000-8000-000000000002","toolID":"search","arguments":{}}"#

        #expect(throws: GnosticProtocolError.self) {
            _ = try JSONDecoder().decode(TimelineStatusRequest.self, from: Data(timeline.utf8))
        }
        #expect(throws: GnosticProtocolError.self) {
            _ = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(workspace.utf8))
        }
    }

    @Test("normal catalog discovery hides incompatible objects while inspection retains them")
    func catalogFiltersIncompatibleObjectsForNormalDiscovery() async throws {
        let objectID = ascendantID.uuidString.lowercased()
        let payload = """
        {"protocolMajor":1,"objectId":"\(objectID)","coreType":"CoatyObject","objectType":"\(GnosticObjectType.ascendant)","name":"Old","ascendantDescription":"legacy","privateTimelineID":"\(timelineID.uuidString.lowercased())","lastActiveAt":"2023-11-14T22:13:20Z","createdAt":"2023-11-14T22:13:20Z","updatedAt":"2023-11-14T22:13:20Z"}
        """
        let snapshot = CoatyObjectSnapshot(
            objectId: objectID,
            coreType: .CoatyObject,
            objectType: GnosticObjectType.ascendant,
            name: "Old",
            payload: payload
        )
        let catalog = NetworkCatalog()
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "old", object: snapshot))

        #expect(await catalog.networkObjects().isEmpty)
        #expect(await catalog.networkObjects(includeIncompatible: true).count == 1)
    }

    @Test("metadata-only advertisements do not evict a full compatible object")
    func metadataOnlyAdvertisementPreservesCompatibleObject() async throws {
        let objectID = ascendantID.uuidString.lowercased()
        let fullPayload = """
        {"protocolMajor":2,"objectId":"\(objectID)","coreType":"CoatyObject","objectType":"\(GnosticObjectType.ascendant)","name":"Current","ascendantDescription":"current","privateTimelineID":"\(timelineID.uuidString.lowercased())","lastActiveAt":"2023-11-14T22:13:20Z","createdAt":"2023-11-14T22:13:20Z","updatedAt":"2023-11-14T22:13:20Z"}
        """
        let full = CoatyObjectSnapshot(objectId: objectID, coreType: .CoatyObject, objectType: GnosticObjectType.ascendant, name: "Current", payload: fullPayload)
        let metadata = CoatyObjectSnapshot(objectId: objectID, coreType: .CoatyObject, objectType: GnosticObjectType.ascendant, name: "Current")
        let catalog = NetworkCatalog()
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "provider", object: full))
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "provider", object: metadata))

        let entries = await catalog.networkObjects()
        #expect(entries.count == 1)
        #expect(entries.first?.protocolMajor == GnosticProtocol.currentMajor)
    }
}
